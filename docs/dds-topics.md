# DDS topic map (Go2, from firmware analysis)

The Go2 runtime is a **CycloneDDS (domain 0) + iceoryx** bus with a ROS2-style
`rt/...` namespace, message schema `unitree_go::msg::dds_`. This is exactly the
interface `unitree_sdk2` / `unitree_ros2` expose. 97 topics were recovered; the full
list is `analysis/topics_all.txt` in the analysis repo. The ones you'll use first:

## State (subscribe — read-only, safe)

| Topic | Meaning |
|---|---|
| `rt/lf/lowstate` | low-level state: motors, IMU, BMS/battery — **hello_lowstate target** |
| `rt/lf/sportmodestate` | high-level sport state (pose, velocity, gait mode) |
| `rt/lf/bmsstate` / `rt/lf/battery_alarm` | battery management / alarms |
| `rt/lowstate` | legacy low-state alias |
| `rt/utlidar/*` | LiDAR: `cloud`, `cloud_deskewed`, `height_map`, `imu`, `robot_pose`, `voxel_map` |
| `rt/uslam/*` | SLAM: `frontend/odom`, `localization/*`, `navigation/global_path` |
| `rt/lio_sam_ros2/mapping/odometry` | LIO-SAM odometry |
| `rt/wirelesscontroller` | joystick / remote input |

## Request/response API (`rt/api/<svc>/{request,response}`)

Each service exposes a request/response pair. Notable services:
`sport` (locomotion), `motion_switcher`, `robot_state`, `obstacles_avoid`, `vui`
(voice UI), `gpt`, `audiohub`, `videohub`, `config`, `bashrunner`.

**Safety:** start with subscribes only. `rt/api/sport/request` and anything that
drives motion is **not** part of the hello-world milestone — validate discovery and
state decode first, then issue a single benign request (e.g. a `robot_state` query)
before touching `sport`.

## Bring-up checklist for an app

1. `ChannelFactory::Init(0, "<iface>")` — domain 0; interface matching the robot.
2. Subscribe `rt/lf/lowstate`; confirm data arrives (proves discovery + decode).
3. Compare the live topic set against this file (`ros2 topic list` equivalent, or the
   CycloneDDS spy) — a mismatch usually means a domain / msg-version drift.
4. Only then attempt a request/response round-trip on a non-motion service.
