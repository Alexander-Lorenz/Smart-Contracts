# oracle_no_env.py
# Run with:  .\.venv\Scripts\python.exe oracle_no_env.py

import math
from web3 import Web3
from typing import Tuple

import openmeteo_requests
import requests_cache
from retry_requests import retry

# --------- EDIT THESE 5 LINES ----------
RPC_URL          = "https://eth-sepolia.g.alchemy.com/v2/mwpVrmlu9WlaldA0Vt2FK"
ORACLE_PRIVKEY   = "dd5af2a6301e0ed42ebcfb318831a0fa37055ca130db035918f4ca86e77672d5"        # reporter wallet (has Sepolia ETH)
CONTRACT_ADDRESS = "0x255f5DAfa391820559E77869CCe96c373483D8c5"    # contract that has checkTrigger(uint)
LAT, LON         = 25.7743, -80.1937            # location to check (Miami example)
TIMEZONE         = "America/New_York"           # or "auto"
THRESH_KMH       = 100                          # optional local pre-check (set None to always call)
LOCATION_LABEL   = "Miami,US"
# ---------------------------------------

# Minimal ABI for your contract UI (only the function we call)
ABI = [
  {
    "inputs":[
      {"internalType":"bytes32","name":"locationId","type":"bytes32"},
      {"internalType":"uint64","name":"speedX100","type":"uint64"},
      {"internalType":"uint64","name":"gustX100","type":"uint64"},
      {"internalType":"int16","name":"directionDeg","type":"int16"}
    ],
    "name":"setWind",
    "outputs":[],
    "stateMutability":"nonpayable",
    "type":"function"
  }
]

def fetch_wind_kmh(lat: float, lon: float, tz: str) -> Tuple[float, float, int]:
    """
    Returns (speed_kmh, gust_kmh, direction_deg or -1).
    Falls back if some fields are missing.
    """
    cache = requests_cache.CachedSession('.cache', expire_after=600)
    session = retry(cache, retries=3, backoff_factor=0.3)
    client = openmeteo_requests.Client(session=session)

    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude":  lat,
        "longitude": lon,
        "current":   ["wind_speed_10m","wind_gusts_10m","wind_direction_10m"],
        "hourly":    ["wind_speed_10m","wind_gusts_10m","wind_direction_10m"],
        "wind_speed_unit": "kmh",
        "timezone": tz,
        "past_hours": 2
    }
    resp = client.weather_api(url, params=params)[0]

    cur = resp.Current()
    def safe_var(idx):
        try:
            v = cur.Variables(idx).Value()
            return None if v is None else float(v)
        except Exception:
            return None

    speed_kmh = safe_var(0)
    gust_kmh  = safe_var(1)
    direction = safe_var(2)  # degrees

    # If current is missing, use latest hourly
    if speed_kmh is None or gust_kmh is None or direction is None:
        h = resp.Hourly()
        n = h.Variables(0).ValuesLength()
        if n == 0:
            raise RuntimeError("No wind data available.")
        # last index
        i = n - 1
        def hv(idx):
            try:
                return float(h.Variables(idx).ValuesAsNumpy()[i])
            except Exception:
                return None
        speed_kmh = hv(0) if speed_kmh is None else speed_kmh
        gust_kmh  = hv(1) if gust_kmh  is None else gust_kmh
        direction = hv(2) if direction is None else direction

    dir_int = int(round(direction)) if direction is not None else -1
    # sanitize direction range
    if dir_int != -1:
        dir_int %= 360
    return float(speed_kmh), float(gust_kmh), dir_int

def kmh_to_mps_x100(v_kmh: float) -> int:
    mps = v_kmh / 3.6
    return int(round(mps * 100))

def main():
    speed_kmh, gust_kmh, direction_deg = fetch_wind_kmh(LAT, LON, TIMEZONE)
    speed_x100 = kmh_to_mps_x100(speed_kmh)
    gust_x100  = kmh_to_mps_x100(gust_kmh)
    print(f"Wind: {speed_kmh:.1f} km/h ({speed_x100} x100 m/s), "
          f"gust {gust_kmh:.1f} km/h ({gust_x100} x100 m/s), dir {direction_deg}°")

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    assert w3.is_connected(), "RPC not reachable"
    acct = w3.eth.account.from_key(ORACLE_PRIVKEY)
    print("Updater address:", acct.address)

    # locationId = keccak256("Miami,US")
    location_id_bytes = Web3.keccak(text=LOCATION_LABEL)

    contract = w3.eth.contract(
        address=Web3.to_checksum_address(CONTRACT_ADDRESS),
        abi=ABI
    )

    fn = contract.functions.setWind(location_id_bytes, speed_x100, gust_x100, direction_deg)

    # Simulate & estimate gas to catch "not updater" or type issues
    try:
        fn.call({"from": acct.address})
        gas_est = fn.estimate_gas({"from": acct.address})
    except ContractLogicError as e:
        raise SystemExit(f"Contract reverted (likely not updater / bad args): {e}")
    except Exception as e:
        raise SystemExit(f"Simulation/estimate failed: {e}")

    latest = w3.eth.get_block("latest")
    base   = latest.get("baseFeePerGas", w3.to_wei("1", "gwei"))
    tip    = w3.to_wei("1", "gwei")
    tx     = fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": math.floor(gas_est * 1.2),
        "maxFeePerGas": base + 2 * tip,
        "maxPriorityFeePerGas": tip,
        "chainId": w3.eth.chain_id
    })

    signed = w3.eth.account.sign_transaction(tx, ORACLE_PRIVKEY)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    print("Submitted tx:", tx_hash.hex())

if __name__ == "__main__":
    main()
