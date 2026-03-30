{
  config,
  lib,
  ...
}:
{
  config.inventory = {
    hosts = {
      utm-nwmqpa = {
        users.enableUsers = [
          "nwmqpa"
        ];
      };
      hetzner-nu1-nwmqpa = {
        users.enableUsers = [
          "nwmqpa"
        ];
      };
      t470s-nwmqpa = {
        users.enableUsers = [
          "nwmqpa"
        ];
      };
    };
  };
}
