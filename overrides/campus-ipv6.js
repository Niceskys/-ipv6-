const main = (config) => {
  config.ipv6 = true;

  if (!config.dns) config.dns = {};
  config.dns.ipv6 = true;

  if (!config.tun) config.tun = {};

  let excludes = Array.isArray(config.tun["route-exclude-address"])
    ? [...config.tun["route-exclude-address"]]
    : [];

  const addExclude = (address) => {
    if (typeof address === "string" && address.length > 0 && !excludes.includes(address)) {
      excludes.push(address);
    }
  };

  addExclude("192.168.100.200/32");
  addExclude("192.168.137.0/24");

  const allProxies = Array.isArray(config.proxies) ? config.proxies : [];

  const isHongKongV6 = (proxy) => {
    if (!proxy || typeof proxy.name !== "string") return false;
    return /香港\s*V6(?:-|\b)/i.test(proxy.name);
  };

  const hkV6Proxies = allProxies.filter(isHongKongV6);
  const hkV6Names = hkV6Proxies.map((proxy) => proxy.name);

  for (const proxy of hkV6Proxies) {
    proxy["ip-version"] = "ipv6";

    if (typeof proxy.server === "string") {
      let server = proxy.server.trim();

      if (server.startsWith("[") && server.endsWith("]")) {
        server = server.slice(1, -1);
      }

      if (server.includes(":")) {
        addExclude(server.includes("/") ? server : server + "/128");
      }
    }
  }

  config.tun["route-exclude-address"] = [...new Set(excludes)];

  if (!Array.isArray(config["proxy-groups"])) {
    config["proxy-groups"] = [];
  }

  const groups = config["proxy-groups"];
  const getGroup = (name) => groups.find((group) => group && group.name === name);

  const crushGroup = getGroup("Crush Cloud");
  const autoGroup = getGroup("自动选择");
  const fallbackGroup = getGroup("故障转移");
  const embyGroup = getGroup("Emby");

  if (hkV6Names.length === 0) {
    config.proxies = [];

    for (const group of groups) {
      if (!group || typeof group.name !== "string") continue;

      if (
        group.name === "Crush Cloud" ||
        group.name === "自动选择" ||
        group.name === "故障转移" ||
        group.name === "Emby"
      ) {
        group.proxies = ["REJECT"];
      }
    }

    return config;
  }

  config.proxies = hkV6Proxies;

  const HEALTH_URL = "http://connect.rom.miui.com/generate_204";

  if (autoGroup) {
    autoGroup.proxies = [...hkV6Names];
    autoGroup.url = HEALTH_URL;
    autoGroup.interval = 300;
    autoGroup.lazy = true;
    autoGroup.timeout = 5000;
    autoGroup.tolerance = 150;
    autoGroup["expected-status"] = 204;
  }

  if (fallbackGroup) {
    fallbackGroup.proxies = [...hkV6Names];
    fallbackGroup.url = HEALTH_URL;
    fallbackGroup.interval = 180;
    fallbackGroup.lazy = true;
    fallbackGroup.timeout = 5000;
    fallbackGroup["max-failed-times"] = 3;
    fallbackGroup["expected-status"] = 204;
  }

  if (crushGroup) {
    crushGroup.proxies = [
      ...(autoGroup ? ["自动选择"] : []),
      ...(fallbackGroup ? ["故障转移"] : []),
      ...hkV6Names,
    ];
  }

  if (embyGroup) {
    embyGroup.proxies = crushGroup ? ["Crush Cloud"] : [...hkV6Names];

    if (Object.prototype.hasOwnProperty.call(embyGroup, "url")) {
      embyGroup.url = HEALTH_URL;
      embyGroup["expected-status"] = 204;
      embyGroup.timeout = 5000;
    }
  }

  return config;
};
