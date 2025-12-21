import Config

config :fc_ex_cp,
  kernel_path: System.get_env("FC_KERNEL"),
  rootfs_path: System.get_env("FC_ROOTFS"),
  warm_target: String.to_integer(System.get_env("FC_WARM", "1")),
  max_vms: String.to_integer(System.get_env("FC_MAX", "5")),
  bridge: System.get_env("FC_BRIDGE", "br0"),
  bridge_cidr: System.get_env("FC_BRIDGE_CIDR", "172.16.0.1/24"),
  subnet_prefix: System.get_env("FC_SUBNET_PREFIX", "172.16.0."),
  outbound_iface: System.get_env("FC_OUT_IFACE"),
  guest_port: String.to_integer(System.get_env("FC_GUEST_PORT", "4000")),
  listen_port: String.to_integer(System.get_env("FC_PORT", "8088")),
  proxy_mode: :none
