// Retro Computers sidebar page. Kept in its own file: Cockpit's content security policy does not run inline scripts.
document.getElementById("open").href = "http://" + location.hostname + "/cp300/";

function set(id, text) { document.getElementById(id).textContent = text; }

// both checks go through Cockpit's own connection to the board: a page served over https cannot call http://
cockpit.spawn(["cat", "/sys/class/uio/uio0/name"], { err: "ignore" }).then(
  function (name) {
    if (name.trim() === "cp300") set("gateware", "Gateware: the CP-300 gateware is loaded.");
    else set("gateware", "Gateware: another design is loaded (uio0 = " + name.trim() + "). Run sudo cp300-load-gateware.");
  },
  function () { set("gateware", "Gateware: the CP-300 gateware is not loaded (no uio0). Run sudo cp300-load-gateware."); });

cockpit.http({ port: 8300 }).get("/api/state").then(
  function (data) {
    var s = JSON.parse(data);
    var roms = s.roms.system && s.roms.chargen ? "ROMs loaded" : "ROMs missing: upload them on the Retro Computers page";
    set("daemon", "Daemon: running, " + roms + ".");
  },
  function () { set("daemon", "Daemon: not running (it starts only with the CP-300 gateware loaded; systemctl status cp300d)."); });
