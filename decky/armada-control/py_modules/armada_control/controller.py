import subprocess

CONTROLLER_TYPE = "/usr/libexec/armada/controller-type"
DEFAULT_TYPE = "deck-uhid"
CONTROLLER_TYPES = {
    "deck-uhid": "Steam Deck",
    "xb360": "Xbox 360",
    "ds5": "DualSense 5",
}


def controller_type():
    try:
        value = subprocess.check_output((CONTROLLER_TYPE, "get"), text=True, timeout=3).strip()
    except (OSError, subprocess.SubprocessError):
        return DEFAULT_TYPE
    return value if value in CONTROLLER_TYPES else DEFAULT_TYPE


def set_controller_type(value):
    if value not in CONTROLLER_TYPES:
        raise ValueError("invalid controller type")
    subprocess.check_call((CONTROLLER_TYPE, "set", value), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    return controller_type()
