const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync("overrides/campus-ipv6.js", "utf8");
const context = {};
vm.createContext(context);
vm.runInContext(source + "\n;globalThis.__campusMain = main;", context);

const main = context.__campusMain;

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const sample = {
  proxies: [
    { name: "[anytls]🇭🇰香港V6-01", server: "hk-v6.example", type: "anytls" },
    { name: "[anytls]🇭🇰香港实验性V4-01", server: "hk-v4.example", type: "anytls" },
    { name: "[anytls]🇯🇵日本V6-01", server: "jp-v6.example", type: "anytls" }
  ],
  dns: {},
  tun: { "route-exclude-address": ["10.0.0.0/8"] },
  "proxy-groups": [
    { name: "Crush Cloud", type: "select", proxies: [] },
    { name: "自动选择", type: "url-test", proxies: [] },
    { name: "故障转移", type: "fallback", proxies: [] },
    { name: "Emby", type: "select", proxies: [] }
  ]
};

const result = main(JSON.parse(JSON.stringify(sample)));
assert(result.proxies.length === 1, "Only one HK V6 proxy should remain");
assert(result.proxies[0].name.includes("香港V6-01"), "HK V6 proxy missing");
assert(result.proxies[0]["ip-version"] === "ipv6", "ip-version must be ipv6");
assert(result.tun["route-exclude-address"].includes("10.0.0.0/8"), "Existing TUN exclude was lost");
assert(result.tun["route-exclude-address"].includes("192.168.100.200/32"), "Campus auth exclude missing");
assert(result.tun["route-exclude-address"].includes("192.168.137.0/24"), "Hotspot exclude missing");

for (const groupName of ["自动选择", "故障转移"]) {
  const group = result["proxy-groups"].find((x) => x.name === groupName);
  assert(group.proxies.length === 1, groupName + " should contain only HK V6");
  assert(group.proxies[0].includes("香港V6-01"), groupName + " contains an unexpected proxy");
}

const noHk = JSON.parse(JSON.stringify(sample));
noHk.proxies = noHk.proxies.filter((x) => !x.name.includes("香港V6-01"));
const closed = main(noHk);
assert(closed.proxies.length === 0, "Fail-closed must clear proxies");

for (const groupName of ["Crush Cloud", "自动选择", "故障转移", "Emby"]) {
  const group = closed["proxy-groups"].find((x) => x.name === groupName);
  assert(group.proxies.length === 1 && group.proxies[0] === "REJECT", groupName + " did not fail closed");
}

console.log("PASS override functional tests");
