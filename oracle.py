import os, math
from dotenv import load_dotenv
from web3 import Web3

import openmeteo_requests
import requests_cache
from retry_requests import retry

load_dotenv()

RPC_URL          = os.getenv("RPC_URL")
PRIVATE_KEY      = os.getenv("ORACLE_PRIVKEY")
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")
LAT        = float(os.getenv("LAT", "25.7743"))
LON        = float(os.getenv("LON", "-80.1937"))
TIMEZONE   = os.getenv("TIMEZONE", "America/New_York")
THRESH_RAW = os.getenv("THRESH_KMH")  # optional local check
THRESH_KMH = int(THRESH_RAW) if THRESH_RAW else None

# Minimal ABI: only what we need
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
    """Return (speed_kmh: float, observed_ts_unix: int)."""
    cache_session = requests_cache.CachedSession('.cache', expire_after=600)
    retry_session = retry(cache_session, retries=3, backoff_factor=0.2)
    client = openmeteo_requests.Client(session=retry_session)

    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude":  lat,
        "longitude": lon,
        "current":   ["wind_speed_10m"],   # change to ["wind_speed_10m","wind_gusts_10m"] if you want gusts
        "wind_speed_unit": "kmh",          # keep units consistent with your threshold
        "timezone": tz,
        "past_hours": 1
    }
    resp = client.weather_api(url, params=params)[0]
    cur = resp.Current()
    speed_kmh = float(cur.Variables(0).Value())
    ts_unix   = int(cur.Time())           # not used by this contract, but handy to log
    return speed_kmh, ts_unix

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    acct = w3.eth.account.from_key(PRIVATE_KEY)
    contract = w3.eth.contract(address=Web3.to_checksum_address(CONTRACT_ADDRESS), abi=ABI)

    speed_kmh, ts = get_current_wind_kmh(LAT, LON, TIMEZONE)
    print(f"Current 10m wind: {speed_kmh:.1f} km/h  (unix {ts})")

    # Optional: skip txs if below your local threshold. If you omit THRESH_KMH, we always call.
    if THRESH_KMH is not None and speed_kmh < THRESH_KMH:
        print(f"Below threshold ({THRESH_KMH} km/h). No transaction sent.")
        return

    # Build & send EIP-1559 tx
    tx_fn = contract.functions.checkTrigger(int(round(speed_kmh)))
    gas_est = tx_fn.estimate_gas({"from": acct.address})
    latest  = w3.eth.get_block("latest")
    base    = latest.get("baseFeePerGas", w3.to_wei("1", "gwei"))
    tip     = w3.to_wei("1", "gwei")
    maxfee  = base + tip * 2

    tx = tx_fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": math.floor(gas_est * 1.2),
        "maxFeePerGas": maxfee,
        "maxPriorityFeePerGas": tip,
        "chainId": w3.eth.chain_id
    })
    signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    print("Submitted tx:", tx_hash.hex())

if __name__ == "__main__":
    main()
