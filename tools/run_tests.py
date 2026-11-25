"""Runs tools/test_motion_melee.lua and syntax-checks the game script with Lua 5.4.
Needs lupa in tools/pydeps: python -m pip install --target tools/pydeps lupa
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "pydeps"))
from lupa.lua54 import LuaRuntime  # noqa: E402

SCRIPTS = os.path.expandvars(r"%APPDATA%\UnrealVRMod\QueensDomain-Win64-Shipping\scripts")


def lua_path(p):
    return p.replace("\\", "/")


lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{lua_path(SCRIPTS)}/libs/?.lua;" .. package.path')

failed = lua.execute(f'return dofile("{lua_path(HERE)}/test_motion_melee.lua")')
for test in ("test_qd_grip.lua", "test_qd_pickup.lua", "test_qd_belt.lua", "test_qd_ik.lua", "test_qd_shoulder.lua", "test_qd_knives.lua", "test_qd_throw.lua", "test_qd_armhud.lua", "test_qd_belt3d.lua", "test_qd_handpose.lua", "test_qd_fastmath.lua", "test_qd_ikfast.lua", "test_qd_statusfx.lua", "test_qd_gamegrip.lua", "test_qd_fingerfit.lua", "test_qd_itemview.lua", "test_qd_gunfix.lua"):
    if os.path.exists(os.path.join(HERE, test)):
        failed += lua.execute(f'return dofile("{lua_path(HERE)}/{test}")')

for script in ("queens_domain_vr.lua", "libs/motion_melee.lua", "libs/qd_grip.lua", "libs/qd_pickup.lua", "libs/qd_belt.lua", "libs/qd_itemview.lua", "libs/qd_gunfix.lua", "libs/qd_ik.lua", "libs/qd_shoulder.lua", "libs/qd_knives.lua", "libs/qd_throw.lua", "libs/qd_armhud.lua", "libs/qd_belt3d.lua", "libs/qd_handpose.lua", "libs/qd_fastmath.lua", "libs/qd_ikfast.lua", "libs/qd_statusfx.lua", "libs/qd_gamegrip.lua", "libs/qd_fingerfit.lua", "libs/ik.lua", "libs/core/math_lib.lua"):
    path = lua_path(os.path.join(SCRIPTS, script))
    ok, err = lua.execute(f'local f, e = loadfile("{path}"); return f ~= nil, e')
    status = "syntax ok" if ok else f"SYNTAX ERROR: {err}"
    print(f"{script}: {status}")
    failed += 0 if ok else 1

sys.exit(1 if failed else 0)
