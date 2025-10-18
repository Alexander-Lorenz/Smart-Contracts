import os, requests, math
from datetime import datetime
from dotenv import load_dotenv
from web3 import Web3

load_dotenv()
RPC_URL          = os.getenv("RPC_URL")
PRIVATE_KEY      = os.getenv("ORACLE_PRIVKEY")
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")
LAT = float(os.getenv("LAT", "25.7743"))
LON = float(os.getenv("LON", "-80.1937"))
THRESH_KMH = int(os.getenv("THRESH_KMH", "100"))

# ABI: only what we call/read
ABI = [
  {"inputs":[{"internalType":"uint256","name":"speedKmh","type":"uint256"},
             {"internalType":"uint256","name":"observedAt","type":"uint256"}],
   "name":"submitObservation","outputs":[],"stateMutability":"nonpayable","type":"function"},
  {"inputs":[],"name":"triggered","outputs":[{"internalType":"bool","name":"","type":"bool"}],
   "stateMutability":"view","type":"function"}
]

def fetch_max_now_kmh(lat, lon):
    """Use current wind & gusts; fallback to max of last 6 hourly values."""
    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude": lat, "longitude": lon,
        "current": ["wind_speed_10m", "wind_gusts_10m"],
        "hourly": ["windspeed_10m"], "past_hours": 6,
        "timezone": "auto", "wind_speed_unit": "kmh"
    }
    r = requests.get(url, params=params, timeout=20)
    r.raise_for_status()
    j = r.json()

    best, t_iso = None, None
    if "current" in j:
        cur = j["current"]
        vals = [v for v in [cur.get("wind_speed_10m"), cur.get("wind_gusts_10m")] if v is not None]
        if vals:
            best = max(vals); t_iso = cur.get("time")

    if best is None and "hourly" in j:
        vals = [v for v in j["hourly"]["windspeed_10m"][-6:] if v is not None]
        if vals:
            best = max(vals); t_iso = j["hourly"]["time"][-1]

    if best is None or t_iso is None:
        raise RuntimeError("No wind data available")

    obs_ts = int(datetime.fromisoformat(t_iso.replace("Z","+00:00")).timestamp())
    return float(best), obs_ts

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    acct = w3.eth.account.from_key(PRIVATE_KEY)
    contract = w3.eth.contract(Web3.to_checksum_address(CONTRACT_ADDRESS), abi=ABI)

    # Stop if already triggered
    if contract.functions.triggered().call():
        print("Contract already triggered. No action.")
        return

    speed, obs_ts = fetch_max_now_kmh(LAT, LON)
    print(f"Observed max near-now: {speed:.1f} km/h @ {obs_ts}")

    if speed < THRESH_KMH:
        print(f"Below threshold ({THRESH_KMH} km/h). No tx.")
        return

    # Build EIP-1559 tx with a safe gas estimate
    tx_fn = contract.functions.submitObservation(int(round(speed)), obs_ts)
    gas_estimate = tx_fn.estimate_gas({"from": acct.address})
    base_fee = w3.eth.get_block("latest")["baseFeePerGas"]
    max_priority = w3.to_wei("1", "gwei")
    max_fee = base_fee + max_priority * 2

    tx = tx_fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": math.floor(gas_estimate * 1.2),  # headroom
        "maxFeePerGas": max_fee,
        "maxPriorityFeePerGas": max_priority,
        "chainId": w3.eth.chain_id
    })

    signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    print("Submitted tx:", tx_hash.hex())

if __name__ == "__main__":
    main()
