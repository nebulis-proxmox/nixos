let
  # Identities
  nwmqpaMain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDdnrldIg416flniTapS18pv/IRwy6y03D+QmjF9euv";

  nwmqpaDerived = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIT3juohQ7S8lU/8T5PEk8peVdDx9IjZCZtWrI30fMij";

  mzlapqMain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9XyQ53ztHRg2u8gMTd1JN+WOeJ2WPe91rcc7gbzJNN";

  virtualbox-nwmqpa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMUPPWoKGmRxJmQq7sz8li1ffBrqMLB633yJa2LaLwh";
  utm-nwmqpa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMUPPWoKGmRxJmQq7sz8li1ffBrqMLB633yJa2LaLwh";
  hetzner-nu1-nwmqpa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICXek+yTaovcgZdode516J17/JH1bImAINt0jaRbPqZK";

  # Groups
  nwmqpa = [
    nwmqpaMain
    nwmqpaDerived
  ];

  mzlapq = [
    mzlapqMain
  ];

  machines = [
    utm-nwmqpa
    virtualbox-nwmqpa
    hetzner-nu1-nwmqpa
  ];

  users = nwmqpa ++ mzlapq;

  all = machines ++ users;

  k8s-control-plane = [
    utm-nwmqpa
    hetzner-nu1-nwmqpa
  ];
in
{
  # User keys

  # Only this key need only the main key to be deciphered
  "nwmqpaDerivedSshKey.age".publicKeys = [ nwmqpaMain ];

  "nwmqpaPassword.age".publicKeys = [
    virtualbox-nwmqpa
    utm-nwmqpa
    hetzner-nu1-nwmqpa
  ]
  ++ nwmqpa;

  # Only this key need only the main key to be deciphered
  "mzlapqDerivedSshKey.age".publicKeys = [ mzlapqMain ];

  "mzlapqPassword.age".publicKeys = [ mzlapqMain ];
  # Machine keys
  "virtualbox-nwmqpa.age".publicKeys = [
    virtualbox-nwmqpa
  ]
  ++ users;

  "utm-nwmqpa.age".publicKeys = [
    utm-nwmqpa
  ]
  ++ users;

  "hetzner-nu1-nwmqpa.age".publicKeys = [
    hetzner-nu1-nwmqpa
  ]
  ++ users;

  "tailscaleKey.age".publicKeys = all;

  # CA keys
  "sa-kubernetes.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
    utm-nwmqpa
  ]
  ++ k8s-control-plane;
  "ca-root.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
  ]
  ++ k8s-control-plane;
  "ca-intermediate.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
  ]
  ++ k8s-control-plane;
  "ca-kubernetes.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
  ]
  ++ k8s-control-plane;
  "ca-etcd.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
  ]
  ++ k8s-control-plane;
  "ca-kubernetes-front-proxy.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
  ]
  ++ k8s-control-plane;
  "ca-typha.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
  ]
  ++ k8s-control-plane;
  # END_SECRETS
}
