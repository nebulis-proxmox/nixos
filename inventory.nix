{
  config,
  lib,
  ...
}:
{
  config.inventory.hosts.utm-nwmqpa.users.enableUsers = [ "nwmqpa" ];
  config.inventory.hosts.hetzner-nu1-nwmqpa.users.enableUsers = [ "nwmqpa" ];
  config.inventory.hosts.t470s-nwmqpa.users.enableUsers = [ "nwmqpa" ];
  config.inventory.hosts.pangolin.users.enableUsers = [ "nwmqpa" ];
  # Other inventory configuration
  config.inventory = {
    hosts = {
      utm-nwmqpa = {

      };
      hetzner-nu1-nwmqpa = {

      };
      t470s-nwmqpa = {

      };
    };
  };
}
