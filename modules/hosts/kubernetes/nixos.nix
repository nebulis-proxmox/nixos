{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.nebulis.kubernetes;
  neworkingCfg = config.nebulis.network;
  tailscaleCfg = config.nebulis.tailscale;

  thenOrNull = condition: value: if condition then value else null;

  indent =
    n: str:
    lib.strings.concatStringsSep ("\n" + (lib.concatStrings (lib.replicate n "\t"))) (
      lib.strings.splitString "\n" str
    );

  ipCommand =
    if cfg.mode == "tailscale" then
      "$(tailscale ip -4)"
    else
      # Ensure no IPv6 addresses are returned nor the loopback address
      "$(ip -json -br a | jq '[.[] | .addr_info[] | select(.prefixlen > 32 | not) | select(.local != \"127.0.0.1\") | .local][0]' -r)";

  tailscaleDnsCommand = thenOrNull (
    cfg.mode == "tailscale"
  ) "$(tailscale dns status | grep -A1 'suffix' | awk '{print $6}' | sed -e 's/)//g')";

  clusterHost =
    if cfg.mode == "tailscale" then
      "${cfg.tailscaleApiServerSvc}.${tailscaleDnsCommand}"
    else
      "${cfg.apiServerHost}";

  clusterAddr =
    "${clusterHost}:" + (if cfg.mode == "tailscale" then "443" else toString cfg.apiServerPort);

  etcdClusterHost =
    if cfg.mode == "tailscale" then
      "${cfg.tailscaleEtcdSvc}.${tailscaleDnsCommand}"
    else
      "${cfg.apiServerHost}";

  etcdClusterAddr =
    "${etcdClusterHost}:" + (if cfg.mode == "tailscale" then "443" else toString cfg.etcdPeerPort);

  pathPackages =
    if cfg.mode == "tailscale" then
      [ tailscaleCfg.package ]
    else
      [
        pkgs.jq
        pkgs.iproute2
      ];

  afterUnits =
    if cfg.mode == "tailscale" then
      [ "tailscaled.service" ]
    else
      (if neworkingCfg.useBr0 then [ "network-addresses-br0.service" ] else [ ]);

  waitForNetwork = ''
    until [ ! -z "${ipCommand}" ] && [ "${ipCommand}" != "null" ]; do
      echo "Waiting for valid IP address..."
      sleep 1
    done
  '';

  waitForDns = thenOrNull (cfg.mode == "tailscale") ''
    until [ ! -z "${tailscaleDnsCommand}" ] && [ "${tailscaleDnsCommand}" != "search" ]; do
      echo "Waiting for Tailscale DNS suffix..."
      sleep 1
    done
  '';

  clusterTestCommand = "curl --silent --fail --insecure \"https://${clusterAddr}/readyz\" --max-time 10 >/dev/null";

  readModuleFile = file: builtins.readFile "${inputs.self}/modules/hosts/kubernetes/${file}";
  readManifest = manifest: readModuleFile "manifests/${manifest}";

  kubeletManifest = readManifest "kubelet.yaml";

  mkCertFunction = readModuleFile "scripts/mkCert.sh";

  mkCert =
    {
      ca,
      cert,
      subject,
      expirationDays,
      altNames ? { },
    }:
    let
      subjectString = lib.strings.concatStrings (
        lib.attrsets.mapAttrsToList (k: v: "/${k}=${v}") subject
      );
      subjectArg = if subjectString == "" then "" else "-subj '${subjectString}'";

      altNamesLine = builtins.concatStringsSep ", " (
        lib.attrsets.mapAttrsToList (
          kind: values:
          builtins.concatStringsSep ", " (map (v: "${kind}:${v}") (lib.lists.filter (v: v != null) values))
        ) altNames
      );

      altNamesExt = if altNamesLine == "" then "" else "subjectAltName = ${altNamesLine}";
      altNamesExtArg = if altNamesExt == "" then "" else "-addext \"${altNamesExt}\"";
      altNamesExtFileArg = if altNamesExt == "" then "" else "-extfile <(echo \"${altNamesExt}\")";
    in
    "mkCert \"${ca}\" \"${cert}\" \"${toString expirationDays}\" \"${subjectString}\" \"${altNamesExt}\"";

  mkKubeconfigFunction =
    builtins.replaceStrings
      [ "$NIX_MK_CERT_WITH_GROUP" "$NIX_MK_CERT" ]
      [
        (mkCert {
          ca = "$ca";
          cert = "$kubeconfig";
          subject = {
            CN = "$username";
            O = "$group";
          };
          expirationDays = "$expirationDays";
        })
        (mkCert {
          ca = "$ca";
          cert = "$kubeconfig";
          subject = {
            CN = "$username";
          };
          expirationDays = "$expirationDays";
        })
      ]
      (readModuleFile "scripts/mkKubeconfig.sh");

  mkKubeconfig =
    {
      ca,
      kubeconfig,
      username,
      group ? "",
      expirationDays,
      isLocal ? false,
    }:
    let
      shadowedClusterAddr = if isLocal then "$ipAddr:${toString cfg.apiServerPort}" else "$clusterAddr";
    in
    "mkKubeconfig \"${ca}\" \"${kubeconfig}\" \"${shadowedClusterAddr}\" \"${toString expirationDays}\" \"${username}\" \"${group}\"";

  adminKubectl = "kubectl --kubeconfig=/etc/kubernetes/admin.conf";

  addLabelOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/addLabelOnNode.sh"
  );
  removeLabelOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/removeLabelOnNode.sh"
  );
  addTaintOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/addTaintOnNode.sh"
  );
  removeTaintOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/removeTaintOnNode.sh"
  );

in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        kubernetes
        openssl
        tcpdump
      ];

      age.secrets = {
        "ca-kubernetes.key".file = inputs.self + "/secrets/ca-kubernetes.key.age";
        "ca-etcd.key".file = inputs.self + "/secrets/ca-etcd.key.age";
        "ca-kubernetes-front-proxy.key".file = inputs.self + "/secrets/ca-kubernetes-front-proxy.key.age";
        "ca-typha.key".file = inputs.self + "/secrets/ca-typha.key.age";
        "sa-kubernetes.key".file = inputs.self + "/secrets/sa-kubernetes.key.age";
      };

      environment.etc = {
        "kubernetes/pki/ca.key" = {
          source = config.age.secrets."ca-kubernetes.key".path;
          mode = "0600";
        };
        "kubernetes/pki/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes.crt";
          mode = "0644";
        };
        "kubernetes/pki/front-proxy-ca.key" = {
          source = config.age.secrets."ca-kubernetes-front-proxy.key".path;
          mode = "0600";
        };
        "kubernetes/pki/front-proxy-ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes-front-proxy.crt";
          mode = "0644";
        };
        "kubernetes/pki/etcd/ca.key" = {
          source = config.age.secrets."ca-etcd.key".path;
          mode = "0600";
        };
        "kubernetes/pki/etcd/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-etcd.crt";
          mode = "0644";
        };
        "kubernetes/pki/typha-ca.key" = {
          source = config.age.secrets."ca-typha.key".path;
          mode = "0600";
        };
        "kubernetes/pki/typha-ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-typha.crt";
          mode = "0644";
        };
        "kubernetes/pki/sa.key" = {
          source = config.age.secrets."sa-kubernetes.key".path;
          mode = "0600";
        };
        "kubernetes/pki/sa.pub" = {
          text = builtins.readFile "${inputs.self}/certs/sa-kubernetes.pub";
          mode = "0644";
        };
      };

      systemd.services = {
        init-kubernetes-cluster = {
          path = [
            pkgs.openssl
            pkgs.jq
            pkgs.curl
            pkgs.gawk
            pkgs.kubernetes
            pkgs.systemd
            pkgs.cri-tools
            pkgs.mount
            pkgs.util-linux
          ]
          ++ pathPackages;
          description = "Initialize Kubernetes cluster";
          documentation = [ "https://kubernetes.io/docs" ];
          after = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];
          enableStrictShellChecks = true;

          script =
            let
              mkApiServerCert = mkCert {
                ca = "/etc/kubernetes/pki/ca";
                cert = "/etc/kubernetes/pki/apiserver";
                subject = {
                  CN = "kube-apiserver";
                };
                altNames = {
                  IP = [
                    "10.96.0.1"
                    "$ipAddr"
                  ];
                  DNS = [
                    "kubernetes"
                    "kubernetes.default"
                    "kubernetes.default.svc"
                    "kubernetes.default.svc.cluster.local"
                    (thenOrNull (tailscaleDnsCommand != null) "$clusterHost")
                    (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleApiServerSvc)
                    config.networking.hostName
                  ];
                };
                expirationDays = 365;
              };

              mkKubeletClientCert = mkCert {
                ca = "/etc/kubernetes/pki/ca";
                cert = "/etc/kubernetes/pki/apiserver-kubelet-client";
                subject = {
                  CN = "kube-apiserver-kubelet-client";
                  O = "kubeadm:cluster-admins";
                };
                expirationDays = 365;
              };

              mkFrontProxyClientCert = mkCert {
                ca = "/etc/kubernetes/pki/front-proxy-ca";
                cert = "/etc/kubernetes/pki/front-proxy-client";
                subject = {
                  CN = "front-proxy-client";
                };
                expirationDays = 365;
              };

              mkEtcdServerCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/etcd/server";
                subject = {
                  CN = config.networking.hostName;
                };
                altNames = {
                  IP = [
                    "$ipAddr"
                    "127.0.0.1"
                    "::1"
                  ];
                  DNS = [
                    (thenOrNull (tailscaleDnsCommand != null) "$etcdClusterHost")
                    (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleEtcdSvc)
                    config.networking.hostName
                    "localhost"
                  ];
                };
                expirationDays = 365;
              };

              mkEtcdPeerCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/etcd/peer";
                subject = {
                  CN = config.networking.hostName;
                };
                altNames = {
                  IP = [
                    "$ipAddr"
                    "127.0.0.1"
                    "::1"
                  ];
                  DNS = [
                    (thenOrNull (tailscaleDnsCommand != null) "$etcdClusterAddr")
                    (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleEtcdSvc)
                    config.networking.hostName
                    "localhost"
                  ];
                };
                expirationDays = 365;
              };

              mkEtcdHealthcheckClientCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/etcd/healthcheck-client";
                subject = {
                  CN = "kube-etcd-healthcheck-client";
                };
                expirationDays = 365;
              };

              mkEtcdApiServerClientCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/apiserver-etcd-client";
                subject = {
                  CN = "kube-apiserver-etcd-client";
                };
                expirationDays = 365;
              };

              mkCalicoTyphaCert = mkCert {
                ca = "/etc/kubernetes/pki/typha-ca";
                cert = "/etc/kubernetes/pki/typha";
                subject = {
                  CN = "calico-typha";
                };
                expirationDays = 365;
              };

              mkKubeletKubeconfig =
                {
                  isLocal ? false,
                }:
                mkKubeconfig {
                  ca = "/etc/kubernetes/pki/ca";
                  kubeconfig = "/etc/kubernetes/kubelet.conf";
                  username = "system:node:${config.networking.hostName}";
                  group = "system:nodes";
                  expirationDays = 1;
                  isLocal = isLocal;
                };

              mkSuperAdminKubeconfig =
                {
                  isLocal ? false,
                }:
                mkKubeconfig {
                  ca = "/etc/kubernetes/pki/ca";
                  kubeconfig = "/etc/kubernetes/admin.conf";
                  username = "kubernetes-super-admin";
                  group = "system:masters";
                  expirationDays = 1;
                  isLocal = isLocal;
                };

              mkControllerManagerKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/controller-manager.conf";
                username = "system:kube-controller-manager";
                expirationDays = 365;
                isLocal = true;
              };

              mkSchedulerKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/scheduler.conf";
                username = "system:kube-scheduler";
                expirationDays = 365;
                isLocal = true;
              };

              mkCalicoKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/calico-cni.conf";
                username = "calico-cni";
                expirationDays = 365;
                isLocal = true;
              };

              coreDnsConfigMap = builtins.toJSON ({
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "coredns";
                  namespace = "kube-system";
                };
                data = {
                  Corefile = ''
                    .:53 {
                      errors
                      health {
                        lameduck 5s
                      }
                      ready
                      kubernetes cluster.local in-addr.arpa ip6.arpa {
                        pods insecure
                        fallthrough in-addr.arpa ip6.arpa
                        ttl 30
                      }
                      prometheus :9153
                      forward . /etc/resolv.conf {
                        max_concurrent 1000
                      }
                      cache 30 {
                        disable success cluster.local
                        disable denial cluster.local
                      }
                      loop
                      reload
                      loadbalance
                    }
                  '';
                };
              });

              coreDnsRoleBinding = builtins.toJSON ({
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "ClusterRoleBinding";
                metadata = {
                  name = "system:coredns";
                };
                roleRef = {
                  apiGroup = "rbac.authorization.k8s.io";
                  kind = "ClusterRole";
                  name = "system:coredns";
                };
                subjects = [
                  {
                    kind = "ServiceAccount";
                    name = "coredns";
                    namespace = "kube-system";
                  }
                ];
              });

              coreDnsServiceAccount = builtins.toJSON ({
                apiVersion = "v1";
                kind = "ServiceAccount";
                metadata = {
                  name = "coredns";
                  namespace = "kube-system";
                };
              });

              coreDnsDeployment = builtins.toJSON ({
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  labels = {
                    "k8s-app" = "kube-dns";
                  };
                  name = "coredns";
                  namespace = "kube-system";
                };
                spec = {
                  replicas = 2;
                  selector = {
                    matchLabels = {
                      "k8s-app" = "kube-dns";
                    };
                  };
                  strategy = {
                    rollingUpdate = {
                      maxUnavailable = 1;
                    };
                    type = "RollingUpdate";
                  };
                  template = {
                    metadata = {
                      labels = {
                        "k8s-app" = "kube-dns";
                      };
                    };
                    spec = {
                      affinity = {
                        podAntiAffinity = {
                          preferredDuringSchedulingIgnoredDuringExecution = [
                            {
                              podAffinityTerm = {
                                labelSelector = {
                                  matchExpressions = [
                                    {
                                      key = "k8s-app";
                                      operator = "In";
                                      values = [ "kube-dns" ];
                                    }
                                  ];
                                };
                                topologyKey = "kubernetes.io/hostname";
                              };
                              weight = 100;
                            }
                          ];
                        };
                      };
                      containers = [
                        {
                          args = [
                            "-conf"
                            "/etc/coredns/Corefile"
                          ];
                          image = "registry.k8s.io/coredns/coredns:v1.12.1";
                          imagePullPolicy = "IfNotPresent";
                          livenessProbe = {
                            failureThreshold = 5;
                            httpGet = {
                              path = "/health";
                              port = "liveness-probe";
                              scheme = "HTTP";
                            };
                            initialDelaySeconds = 60;
                            successThreshold = 1;
                            timeoutSeconds = 5;
                          };
                          name = "coredns";
                          ports = [
                            {
                              containerPort = 53;
                              name = "dns";
                              protocol = "UDP";
                            }
                            {
                              containerPort = 53;
                              name = "dns-tcp";
                              protocol = "TCP";
                            }
                            {
                              containerPort = 9153;
                              name = "metrics";
                              protocol = "TCP";
                            }
                            {
                              containerPort = 8080;
                              name = "liveness-probe";
                              protocol = "TCP";
                            }
                            {
                              containerPort = 8181;
                              name = "readiness-probe";
                              protocol = "TCP";
                            }
                          ];
                          readinessProbe = {
                            httpGet = {
                              path = "/ready";
                              port = "readiness-probe";
                              scheme = "HTTP";
                            };
                          };
                          resources = {
                            limits = {
                              memory = "170Mi";
                            };
                            requests = {
                              cpu = "100m";
                              memory = "70Mi";
                            };
                          };
                          securityContext = {
                            allowPrivilegeEscalation = false;
                            capabilities = {
                              add = [ "NET_BIND_SERVICE" ];
                              drop = [ "ALL" ];
                            };
                            readOnlyRootFilesystem = true;
                          };
                          volumeMounts = [
                            {
                              mountPath = "/etc/coredns";
                              name = "config-volume";
                              readOnly = true;
                            }
                          ];
                        }
                      ];
                      dnsPolicy = "Default";
                      nodeSelector = {
                        "kubernetes.io/os" = "linux";
                      };
                      priorityClassName = "system-cluster-critical";
                      serviceAccountName = "coredns";
                      tolerations = [
                        {
                          key = "CriticalAddonsOnly";
                          operator = "Exists";
                        }
                        {
                          effect = "NoSchedule";
                          key = "node-role.kubernetes.io/control-plane";
                        }
                      ];
                      volumes = [
                        {
                          configMap = {
                            items = [
                              {
                                key = "Corefile";
                                path = "Corefile";
                              }
                            ];
                            name = "coredns";
                          };
                          name = "config-volume";
                        }
                      ];
                    };
                  };
                };
                status = { };
              });

              coreDnsService = builtins.toJSON ({
                apiVersion = "v1";
                kind = "Service";
                metadata = {
                  annotations = {
                    "prometheus.io/port" = "9153";
                    "prometheus.io/scrape" = "true";
                  };
                  labels = {
                    "k8s-app" = "kube-dns";
                    "kubernetes.io/cluster-service" = "true";
                    "kubernetes.io/name" = "CoreDNS";
                  };
                  name = "kube-dns";
                  namespace = "kube-system";
                  resourceVersion = "0";
                };
                spec = {
                  clusterIP = "10.96.0.10";
                  ports = [
                    {
                      name = "dns";
                      port = 53;
                      protocol = "UDP";
                      targetPort = 53;
                    }
                    {
                      name = "dns-tcp";
                      port = 53;
                      protocol = "TCP";
                      targetPort = 53;
                    }
                    {
                      name = "metrics";
                      port = 9153;
                      protocol = "TCP";
                      targetPort = 9153;
                    }
                  ];
                  selector = {
                    "k8s-app" = "kube-dns";
                  };
                };
                status = {
                  loadBalancer = { };
                };
              });

              kubeProxyConfig = ''
                apiVersion: kubeproxy.config.k8s.io/v1alpha1
                bindAddress: 0.0.0.0
                bindAddressHardFail: false
                clientConnection:
                  acceptContentTypes: ""
                  burst: 0
                  contentType: ""
                  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
                  qps: 0
                clusterCIDR: ""
                configSyncPeriod: 0s
                conntrack:
                  maxPerCore: null
                  min: null
                  tcpBeLiberal: false
                  tcpCloseWaitTimeout: null
                  tcpEstablishedTimeout: null
                  udpStreamTimeout: 0s
                  udpTimeout: 0s
                detectLocal:
                  bridgeInterface: ""
                  interfaceNamePrefix: ""
                detectLocalMode: ""
                enableProfiling: false
                healthzBindAddress: ""
                hostnameOverride: ""
                iptables:
                  localhostNodePorts: null
                  masqueradeAll: false
                  masqueradeBit: null
                  minSyncPeriod: 0s
                  syncPeriod: 0s
                ipvs:
                  excludeCIDRs: null
                  minSyncPeriod: 0s
                  scheduler: ""
                  strictARP: false
                  syncPeriod: 0s
                  tcpFinTimeout: 0s
                  tcpTimeout: 0s
                  udpTimeout: 0s
                kind: KubeProxyConfiguration
                logging:
                  flushFrequency: 0
                  options:
                    json:
                      infoBufferSize: "0"
                    text:
                      infoBufferSize: "0"
                  verbosity: 0
                metricsBindAddress: ""
                mode: ""
                nftables:
                  masqueradeAll: false
                  masqueradeBit: null
                  minSyncPeriod: 0s
                  syncPeriod: 0s
                nodePortAddresses: null
                oomScoreAdj: null
                portRange: ""
                showHiddenMetricsForVersion: ""
                winkernel:
                  enableDSR: false
                  forwardHealthCheckVip: false
                  networkName: ""
                  rootHnsEndpointName: ""
                  sourceVip: ""
              '';

              kubeProxyKubeconfig = ''
                apiVersion: v1
                kind: Config
                clusters:
                - cluster:
                    certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                    server: https://$clusterAddr
                  name: default
                contexts:
                - context:
                    cluster: default
                    namespace: default
                    user: default
                  name: default
                current-context: default
                users:
                - name: default
                  user:
                    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
              '';

              kubeProxyConfigMap = (
                builtins.toJSON ({
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  metadata = {
                    name = "kube-proxy";
                    namespace = "kube-system";
                    annotations = {
                      "kubeadm.kubernetes.io/component-config.hash" = "sha256:${
                        builtins.hashString "sha256" (kubeProxyConfig + kubeProxyKubeconfig)
                      }";
                    };
                    labels = {
                      app = "kube-proxy";
                    };
                  };
                  data = {
                    "config.conf" = kubeProxyConfig;
                    "kubeconfig.conf" = kubeProxyKubeconfig;
                  };
                })
              );

              kubeProxyDaemonSet = lib.escape [ "$(" ] (
                builtins.toJSON ({
                  apiVersion = "apps/v1";
                  kind = "DaemonSet";
                  metadata = {
                    labels = {
                      "k8s-app" = "kube-proxy";
                    };
                    name = "kube-proxy";
                    namespace = "kube-system";
                  };
                  spec = {
                    selector = {
                      matchLabels = {
                        "k8s-app" = "kube-proxy";
                      };
                    };
                    template = {
                      metadata = {
                        labels = {
                          "k8s-app" = "kube-proxy";
                        };
                      };
                      spec = {
                        containers = [
                          {
                            command = [
                              "/usr/local/bin/kube-proxy"
                              "--config=/var/lib/kube-proxy/config.conf"
                              "--hostname-override=$(NODE_NAME)"
                            ];
                            env = [
                              {
                                name = "NODE_NAME";
                                valueFrom = {
                                  fieldRef = {
                                    fieldPath = "spec.nodeName";
                                  };
                                };
                              }
                            ];
                            image = "registry.k8s.io/kube-proxy:v1.34.3";
                            imagePullPolicy = "IfNotPresent";
                            name = "kube-proxy";
                            resources = { };
                            securityContext = {
                              privileged = true;
                            };
                            volumeMounts = [
                              {
                                mountPath = "/var/lib/kube-proxy";
                                name = "kube-proxy";
                              }
                              {
                                mountPath = "/run/xtables.lock";
                                name = "xtables-lock";
                              }
                              {
                                mountPath = "/lib/modules";
                                name = "lib-modules";
                                readOnly = true;
                              }
                            ];
                          }
                        ];
                        hostNetwork = true;
                        nodeSelector = {
                          "kubernetes.io/os" = "linux";
                        };
                        priorityClassName = "system-node-critical";
                        serviceAccountName = "kube-proxy";
                        tolerations = [
                          {
                            operator = "Exists";
                          }
                        ];
                        volumes = [
                          {
                            configMap = {
                              name = "kube-proxy";
                            };
                            name = "kube-proxy";
                          }
                          {
                            hostPath = {
                              path = "/run/xtables.lock";
                              type = "FileOrCreate";
                            };
                            name = "xtables-lock";
                          }
                          {
                            hostPath = {
                              path = "/lib/modules";
                            };
                            name = "lib-modules";
                          }
                        ];
                      };
                    };
                    updateStrategy = {
                      type = "RollingUpdate";
                    };
                  };
                  status = {
                    currentNumberScheduled = 0;
                    desiredNumberScheduled = 0;
                    numberMisscheduled = 0;
                    numberReady = 0;
                  };
                })
              );

              kubeProxyServiceAccount = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "v1";
                  kind = "ServiceAccount";
                  metadata = {
                    name = "kube-proxy";
                    namespace = "kube-system";
                  };
                })
              );

              kubeProxyRoleBinding = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "rbac.authorization.k8s.io/v1";
                  kind = "ClusterRoleBinding";
                  metadata = {
                    name = "kube-proxy";
                  };
                  roleRef = {
                    apiGroup = "rbac.authorization.k8s.io";
                    kind = "ClusterRole";
                    name = "system:node-proxier";
                  };
                  subjects = [
                    {
                      kind = "ServiceAccount";
                      name = "kube-proxy";
                      namespace = "kube-system";
                    }
                  ];
                })
              );

              kubeProxyRole = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "rbac.authorization.k8s.io/v1";
                  kind = "Role";
                  metadata = {
                    name = "kube-proxy";
                  };
                  rules = [
                    {
                      apiGroups = [ "" ];
                      resourceNames = [ "kube-proxy" ];
                      resources = [ "configmaps" ];
                      verbs = [ "get" ];
                    }
                  ];
                })
              );

              kubeProxyRoleBindingNode = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "rbac.authorization.k8s.io/v1";
                  kind = "RoleBinding";
                  metadata = {
                    name = "kube-proxy";
                    namespace = "kube-system";
                  };
                  roleRef = {
                    apiGroup = "rbac.authorization.k8s.io";
                    kind = "Role";
                    name = "kube-proxy";
                  };
                  subjects = [
                    {
                      kind = "Group";
                      name = "system:nodes";
                    }
                    {
                      kind = "Group";
                      name = "system:bootstrappers:kubeadm:default-node-token";
                    }
                  ];
                })
              );

              calicoClusterRole = readManifest "calico-cni.cluster-role.yaml";
              calicoTyphaClusterRole = readManifest "calico-typha.cluster-role.yaml";
              calicoTyphaDeployment = readManifest "calico-typha.deployment.yaml";
              calicoTyphaService = readManifest "calico-typha.service.yaml";

              apiServerCertExtraSans = [
                "kubernetes"
                "kubernetes.default"
                "kubernetes.default.svc"
                "kubernetes.default.svc.cluster.local"
                (thenOrNull (tailscaleDnsCommand != null) "$clusterHost")
                (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleApiServerSvc)
                config.networking.hostName
              ];

              crictl = "${pkgs.cri-tools}/bin/crictl";
            in
            ''
              ${mkCertFunction}
              ${mkKubeconfigFunction}

              ${waitForNetwork}
              ${waitForDns}

              clusterAddr="${clusterAddr}"
              ipAddr="${ipCommand}"

              if ${clusterTestCommand}; then
              	echo "Kubernetes API server is already running, skipping initialization of cluster."
              else
              	echo "Initializing Kubernetes cluster..."

              	# Pull required images
                kubeadm config images pull \
                  --image-repository="registry.k8s.io" \
                  --kubernetes-version="v1.34.3"

                kubeadm init \
                  --apiserver-advertise-address="$ipAddr" \
                  --apiserver-bind-port="${toString cfg.apiServerPort}" \
                  --cert-dir="/etc/kubernetes/pki" \
                  --control-plane-endpoint="$clusterAddr" \
                  --image-repository="registry.k8s.io" \
                  --kubernetes-version="v1.34.3" \
                  --node-name="${config.networking.hostName}" \
                  --service-dns-domain="cluster.local" \
                  --skip-certificate-key-print \
                  --skip-token-print \
                  --skip-phases="upload-config,upload-certs,mark-control-plane,bootstrap-token,kubelet-finalize,addon,show-join-command"

                ${thenOrNull (
                  cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)
                ) "systemctl start tailscale-${cfg.tailscaleApiServerSvc}-svc.service"}

                # ONLY WITH TAILSCALE
                # ip netns add vips0
                # ip link add veth-default type veth peer name veth-vips0
                # ip link set veth-vips0 netns vips0
                # ip addr add 10.0.3.1/24 dev veth-default
                # ip netns exec vips0 ip addr add 10.0.3.2/24 dev veth-vips0
                # ip link set veth-default up
                # ip netns exec vips0 ip link set veth-vips0 up
                # ip netns exec vips0 ip route add default via 10.0.3.1

              	until ${clusterTestCommand}; do
              		echo "Waiting for Kubernetes API server to be ready..."
              		sleep 1
              	done

                kubeadm init \
                  --apiserver-advertise-address="$ipAddr" \
                  --apiserver-bind-port="${toString cfg.apiServerPort}" \
                  --cert-dir="/etc/kubernetes/pki" \
                  --control-plane-endpoint="$clusterAddr" \
                  --image-repository="registry.k8s.io" \
                  --kubernetes-version="v1.34.3" \
                  --node-name="${config.networking.hostName}" \
                  --service-dns-domain="cluster.local" \
                  --skip-certificate-key-print \
                  --skip-token-print \
                  --skip-phases="preflight,certs,kubeconfig,etcd,control-plane,kubelet-start"
              fi
            '';
        };
        kubelet = {
          description = "Kubelet";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          after = [
            "init-kubernetes-cluster.service"
          ];
          requires = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];
          before = [ "tailscale-svcs.target" ];
          path = [
            pkgs.kubernetes
            pkgs.coreutils
            pkgs.mount
            pkgs.util-linux
          ];

          serviceConfig = {
            ExecCondition = ''
              ${pkgs.coreutils}/bin/test -f /etc/kubernetes/kubelet.conf
            '';
            ExecStart = ''
              ${pkgs.kubernetes}/bin/kubelet \
                --config=/var/lib/kubelet/config.yaml \
                --kubeconfig=/etc/kubernetes/kubelet.conf \
                --v=2
            '';
            Restart = "on-failure";
            RestartSec = "5";
          };
        };
      };
    })
    (lib.mkIf (cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)) {
      nebulis.tailscale = {
        tags = [
          "kubernetes-control-plane"
        ];

        services = {
          "${cfg.tailscaleApiServerSvc}" = {
            mode = "tcp";
            port = 443;
            target = "127.0.0.1:${toString cfg.apiServerPort}";
            requires = [ "kubelet.service" ];
          };
        };
      };
    })
    {
      assertions = lib.mkIf cfg.enable [
        {
          assertion = cfg.enable -> (cfg.mode == "tailscale" -> tailscaleCfg.enable);
          message = "Error: Kubernetes control plane mode 'tailscale' requires Tailscale to be enabled.";
        }
        {
          assertion = cfg.enable -> (builtins.length cfg.kind) > 0;
          message = "Error: Kubernetes kind must have at least one of 'control-plane' or 'worker'.";
        }
      ];
    }
  ];
}
