(function () {
  "use strict";

  var SEGMENTS_COUNT = 30;
  var POLL_INTERVAL_MS = 1000;

  function formatDuration(totalSeconds) {
    var sec = Math.max(0, Math.floor(Number(totalSeconds) || 0));
    var minutes = Math.floor(sec / 60);
    var seconds = sec % 60;
    var mm = minutes < 10 ? "0" + String(minutes) : String(minutes);
    var ss = seconds < 10 ? "0" + String(seconds) : String(seconds);
    return mm + ":" + ss;
  }

  function computeFilledSegments(task) {
    var state = task.state || "pending";
    if (state === "completed") {
      return SEGMENTS_COUNT;
    }
    if (state === "pending") {
      return 0;
    }
    var elapsed = Math.max(0, Number(task.elapsed) || 0);
    var eta = Math.max(1, Number(task.eta) || 60);
    var ratio = Math.min(0.96, elapsed / eta);
    return Math.max(1, Math.round(ratio * SEGMENTS_COUNT));
  }

  function buildProgressBar(task) {
    var bar = document.createElement("div");
    bar.setAttribute("class", "progress-bar");

    var state = task.state || "pending";
    var filled = computeFilledSegments(task);

    for (var i = 0; i < SEGMENTS_COUNT; i++) {
      var seg = document.createElement("div");
      var cls = "progress-segment";
      if (i < filled) {
        if (state === "completed") {
          cls += " filled-completed";
        } else if (state === "failed") {
          cls += " filled-failed";
        } else if (state === "in-progress") {
          if (i === filled - 1) {
            cls += " filled-running-head";
          } else {
            cls += " filled-running";
          }
        }
      }
      seg.setAttribute("class", cls);
      bar.appendChild(seg);
    }

    return bar;
  }

  function createSeparatorCell() {
    var sep = document.createElement("div");
    sep.setAttribute("class", "col-sep");
    sep.setAttribute("aria-hidden", "true");
    sep.textContent = "|";
    return sep;
  }

  function buildTaskRow(task) {
    var state = String(task.state || "pending");
    var row = document.createElement("div");
    row.setAttribute("class", "table-row row-" + state);
    row.setAttribute("role", "row");

    var colProgress = document.createElement("div");
    colProgress.setAttribute("class", "col-progress");
    colProgress.setAttribute("role", "cell");
    colProgress.appendChild(buildProgressBar(task));

    var colTime = document.createElement("div");
    colTime.setAttribute("class", "col-time");
    colTime.setAttribute("role", "cell");
    colTime.textContent = formatDuration(task.elapsed || 0);

    var colState = document.createElement("div");
    colState.setAttribute("class", "col-state state-" + state);
    colState.setAttribute("role", "cell");
    colState.textContent = state;

    var colTask = document.createElement("div");
    colTask.setAttribute("class", "col-task");
    colTask.setAttribute("role", "cell");
    colTask.textContent = String(task.name || "");

    row.appendChild(colProgress);
    row.appendChild(createSeparatorCell());
    row.appendChild(colTime);
    row.appendChild(createSeparatorCell());
    row.appendChild(colState);
    row.appendChild(createSeparatorCell());
    row.appendChild(colTask);

    return row;
  }

  function renderStatus(data) {
    if (!data || typeof data !== "object") {
      return;
    }

    var titleEl = document.getElementById("board-title");
    if (titleEl && typeof data.title === "string" && data.title.length > 0) {
      titleEl.textContent = data.title;
    }

    var tbody = document.getElementById("tasks-body");
    if (!tbody) {
      return;
    }

    var tasks = Array.isArray(data.tasks) ? data.tasks : [];
    var rows = [];
    for (var i = 0; i < tasks.length; i++) {
      rows.push(buildTaskRow(tasks[i]));
    }
    tbody.replaceChildren.apply(tbody, rows);
  }

  function fetchStatus() {
    fetch("/status.json", {
      method: "GET",
      headers: { Accept: "application/json" },
      cache: "no-store"
    })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("HTTP status " + response.status);
        }
        return response.json();
      })
      .then(function (data) {
        renderStatus(data);
      })
      .catch(function () {
        // Keep displaying the last known state if the server is temporarily unreachable
      });
  }

  document.addEventListener("DOMContentLoaded", function () {
    fetchStatus();
    window.setInterval(fetchStatus, POLL_INTERVAL_MS);
  });
})();
