// hello_lowstate — first Layer-2 milestone.
//
// Subscribes to the Go2 low-level state topic (rt/lf/lowstate) over CycloneDDS
// (domain 0) and prints battery / IMU / a couple of joint readings. READ-ONLY:
// it never publishes a command. This proves the app can discover and decode the
// robot's DDS bus before we attempt anything that moves the robot.
//
// Build: see ../CMakeLists.txt (cross-compiled for aarch64).
// Run:   on the robot (or the RK3588 rootfs) alongside the running master_service.
//        Ensure the DDS domain / network interface matches the robot.
//
// Topic + type confirmed from the firmware analysis:
//   topic: "rt/lf/lowstate"   type: unitree_go::msg::dds_::LowState_
//
// NOTE: this file compiles against unitree_sdk2 once it is fetched
// (scripts/fetch_sources.sh) and the include/lib paths are wired. Until then it
// is the reference skeleton for the milestone.

#include <unitree/robot/channel/channel_subscriber.hpp>
#include <unitree/idl/go2/LowState_.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>

using unitree::robot::ChannelSubscriber;
using unitree_go::msg::dds_::LowState_;

static constexpr char kTopic[] = "rt/lf/lowstate";
static std::atomic<uint64_t> g_count{0};

static void OnLowState(const void* message) {
  const auto& s = *static_cast<const LowState_*>(message);
  const uint64_t n = ++g_count;
  if (n % 100 == 1) {  // ~500 Hz bus; throttle prints
    std::printf(
        "[lowstate #%llu] soc=%u%%  volt=%.2fV  imu_rpy=[%.3f %.3f %.3f]  q0=%.3f\n",
        static_cast<unsigned long long>(n),
        s.bms_state().soc(),
        s.power_v(),
        s.imu_state().rpy()[0], s.imu_state().rpy()[1], s.imu_state().rpy()[2],
        s.motor_state()[0].q());
  }
}

int main(int argc, char** argv) {
  // Arg 1 optionally selects the network interface the robot's DDS is on
  // (e.g. "eth0"); default lets CycloneDDS auto-discover on domain 0.
  const char* iface = (argc > 1) ? argv[1] : "";
  unitree::robot::ChannelFactory::Instance()->Init(0 /*domain*/, iface);

  ChannelSubscriber<LowState_> sub(kTopic);
  sub.InitChannel(OnLowState, 10);
  std::printf("subscribed to %s (domain 0, iface='%s'); waiting for data...\n",
              kTopic, iface);

  for (;;) std::this_thread::sleep_for(std::chrono::seconds(1));
  return 0;
}
