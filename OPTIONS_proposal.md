# Options cleanup proposal (plan step 24), awaiting approval

Plan: **KEEP** options stay in the main panel, grouped. **DEV** options move under a collapsed "Developer" header (configui `collapsing_header`). Their values and saved config stay as they are. **DROP** options are removed: the widget goes and the code keeps the current default.

## KEEP (about 27)
- Combat: 6dof_right (motion melee), motion_swing_speed, motion_swing_cooldown (flurry misses depend on it), charge_on_swing, still_release_cancel, charge_haptics, hit_haptics, motion_hit_window, l2_native_dodge, l2_stab_gesture
- Movement: rstick_turn, rstick_turn_speed, rstick_dodge, disable_dodge
- Items: pickup_assist, pickup_auto_take, pickup_beam, belt, belt_slots, belt_drop, shoulder_switch
- Aim/UI: aim_dot, aim_dot_size, hide_knife_model, game_crosshair, crosshair_size, ui_y_offset
- Body: ik_arms (experimental)

## DEV, hidden under the collapsed header (about 60)
- Weapon grip offsets: loc_x/y/z, rot_yaw/roll/pitch, scale
- Hitbox tuning: debug_hitboxes, hitbox_forward_offset, spear_reach, blade_offset/reach/side/flat
- Detection tuning: stab_outward, stab_axis, rush_buffer, rush_earliest
- Rendering workarounds: weapon_fov_fix, weapon_fpfov, crosshair_on_top, crosshair_bold, game_crosshair_gaze, no_late_update
- Pickup tuning: pickup_auto_hold, pickup_cone, pickup_range, auto_grip
- Layout: frame_layout (you always use it), roomscale (A/B test)
- HUD placement: item_hud_* (13 sliders), hp_hud_* (10), compass_d*/r* (6)
- Cheat: constant_attack

## DROP
- verical_status_bar: its label already says it's unused, and nothing in the code reads it.
- plain_weapon_mat: an old sway workaround, off by default. The code keeps the "off" path.

Reply "approved", or list the changes you want, e.g. "keep X visible" or "don't drop Y".
