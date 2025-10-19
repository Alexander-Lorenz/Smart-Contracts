# oracle_no_env.py
# Run with:  .\.venv\Scripts\python.exe oracle_no_env.py

import math
from web3 import Web3

import openmeteo_requests
import requests_cache
from retry_requests import retry

# --------- EDIT THESE 5 LINES ----------
RPC_URL          = "https://sepolia...YOUR_PROVIDER_ENDPOINT..."
ORACLE_PRIVKEY   = "0xYOUR_PRIVATE_KEY"         # reporter wallet (has Sepolia ETH)
CONTRACT_ADDRESS = "0xYourDeployedContract"     # contract that has checkTrigger(uint)
LAT, LON         = 25.7743, -80.1937            # location to check (Miami example)
TIMEZONE         = "America/New_York"           # or "auto"
THRESH_KMH       = 100                          # optional local pre-check (set None to always call)
# ---------------------------------------

# Minimal ABI for your contract UI (only the function we call)
ABI = [
  {
    "inputs":[{"internalType":"uint256","name":"windspeed","type":"uint256"}],
    "name":"checkTrigger",
    "outputs":[],
    "stateMutability":"nonpayable",
    "type":"function"
  }
]

def get_current_wind_kmh(lat: float, lon: float, tz: str):
    """Return (speed_kmh: float, observed_ts_unix: int) using Open-Meteo."""
    cache_session = requests_cache.CachedSession('.cache', expire_after=600)
    retry_session = retry(cache_session, retries=3, backoff_factor=0.2)
    client = openmeteo_requests.Client(session=retry_session)

    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude":  lat,
        "longitude": lon,
        "current":   ["wind_speed_10m"],
        "wind_speed_unit": "kmh",     # keep threshold units consistent
        "timezone": tz,
        "past_hours": 1               # small buffer if "current" is briefly None
    }
    resp = client.weather_api(url, params=params)[0]
    cur = resp.Current()
    speed_kmh = float(cur.Variables(0).Value())
    ts_unix   = int(cur.Time())
    return speed_kmh, ts_unix

def main():
    # 1) Read wind
    speed_kmh, ts = get_current_wind_kmh(LAT, LON, TIMEZONE)
    print(f"Current 10m wind: {speed_kmh:.1f} km/h  (unix {ts})")

    # 2) Optional local filter to avoid spam txs
    if THRESH_KMH is not None and speed_kmh < THRESH_KMH:
        print(f"Below threshold ({THRESH_KMH} km/h). No transaction.")
        return

    # 3) Send tx to your Sepolia contract
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    acct = w3.eth.account.from_key(ORACLE_PRIVKEY)
    contract = w3.eth.contract(address=Web3.to_checksum_address(CONTRACT_ADDRESS), abi=ABI)

    tx_fn = contract.functions.checkTrigger(int(round(speed_kmh)))
    gas_est = tx_fn.estimate_gas({"from": acct.address})
    latest  = w3.eth.get_block("latest")
    base    = latest.get("baseFeePerGas", w3.to_wei("1", "gwei"))
    tip     = w3.to_wei("1", "gwei")
    maxfee  = base + 2 * tip

    tx = tx_fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": math.floor(gas_est * 1.2),
        "maxFeePerGas": maxfee,
        "maxPriorityFeePerGas": tip,
        "chainId": w3.eth.chain_id
    })
    signed = w3.eth.account.sign_transaction(tx, ORACLE_PRIVKEY)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    print("Submitted tx:", tx_hash.hex())

#if __name__ == "__main__":
    #main()
speed_kmh, ts = get_current_wind_kmh(LAT, LON, TIMEZONE)
print(speed_kmh, ts)
