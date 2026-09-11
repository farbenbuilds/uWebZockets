// Adapted from denoland/fastwebsockets autobahn/server-test.js.

const test_directory = decodeURIComponent(
  new URL(".", import.meta.url).pathname,
);
const repository_directory = decodeURIComponent(
  new URL("../..", import.meta.url).pathname,
);
const reports_directory = decodeURIComponent(
  new URL("./reports", import.meta.url).pathname,
);
const baseline_path = `${test_directory}/baseline.json`;
const source_config_path = `${test_directory}/fuzzingclient.json`;
const report_path = `${reports_directory}/servers/index.json`;
const server_binary = `${repository_directory}/zig-out/bin/autobahn_server`;
const agent_name = "uWebZockets";
const case_batches = [
  ["1.*", "2.*", "3.*", "4.*", "5.*", "6.*", "7.*", "9.*", "10.*", "11.*"],
  ["12.1.*"],
  ["12.2.*"],
  ["12.3.*"],
  ["12.4.*"],
  ["12.5.*"],
  ["13.1.*"],
  ["13.2.*"],
  ["13.3.*"],
  ["13.4.*"],
  ["13.5.*"],
  ["13.6.*"],
  ["13.7.*"],
];

const autobahn_testsuite_docker =
  "crossbario/autobahn-testsuite:0.8.2@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074";
const expected_baseline = await load_baseline();

await reset_reports();
const reports_owner = await Deno.stat(reports_directory);
const docker_user = container_user(reports_owner);

const agent_report = await run_testsuite();

verify_baseline(agent_report, expected_baseline);

const results = Object.values(agent_report);
const protocol_counts = classification_counts(results, "behavior");
const close_counts = classification_counts(results, "behaviorClose");

console.log(JSON.stringify(results, null, 2));
console.log(
  `%c${results.length} / ${expected_baseline.totals.total} cases match the baseline`,
  "color: green",
);
console.log(`protocol: ${describe_counts(protocol_counts)}`);
console.log(`close: ${describe_counts(close_counts)}`);

async function load_baseline() {
  const document = JSON.parse(await Deno.readTextFile(baseline_path));
  require_record(document, "Autobahn baseline");

  if (document.schema_version !== 1) {
    throw new Error("Autobahn baseline has an unsupported schema version");
  }

  const suite = require_record(document.suite, "Autobahn baseline suite");
  if (suite.image !== autobahn_testsuite_docker) {
    throw new Error("Autobahn baseline does not match the pinned Docker image");
  }

  const totals = read_totals(document.totals);
  const default_outcome = read_outcome(
    document.default_outcome,
    "default outcome",
  );
  const overrides = require_record(
    document.outcome_overrides,
    "Autobahn baseline outcome overrides",
  );
  const case_ranges = document.case_ranges;
  if (!Array.isArray(case_ranges)) {
    throw new Error("Autobahn baseline case_ranges must be an array");
  }

  const cases = new Map();
  for (const [index, value] of case_ranges.entries()) {
    const label = `case_ranges[${index}]`;
    const range = require_record(value, label);
    const prefix = range.prefix;
    if (
      typeof prefix !== "string" ||
      !/^[1-9][0-9]*(?:\.[1-9][0-9]*)*$/.test(prefix)
    ) {
      throw new Error(`Autobahn baseline ${label} has an invalid prefix`);
    }

    const first = read_positive_integer(range.first, `${label}.first`);
    const last = read_positive_integer(range.last, `${label}.last`);
    if (last < first) {
      throw new Error(`Autobahn baseline ${label} is reversed`);
    }

    for (let number = first; number <= last; number += 1) {
      const case_id = `${prefix}.${number}`;
      if (cases.has(case_id)) {
        throw new Error(`Autobahn baseline repeats case ${case_id}`);
      }
      cases.set(case_id, default_outcome);
    }
  }

  for (const [case_id, value] of Object.entries(overrides)) {
    if (!cases.has(case_id)) {
      throw new Error(`Autobahn baseline overrides unknown case ${case_id}`);
    }
    cases.set(case_id, read_outcome(value, `case ${case_id}`));
  }

  if (cases.size !== totals.total) {
    throw new Error(
      `Autobahn baseline declares ${totals.total} cases but expands to ${cases.size}`,
    );
  }

  const expected_results = [...cases.values()];
  verify_classifications(
    "protocol",
    classification_counts(expected_results, "behavior"),
    totals,
  );
  verify_classifications(
    "close",
    classification_counts(expected_results, "behaviorClose"),
    totals,
  );

  return Object.freeze({ cases, totals });
}

function classification_counts(results, field) {
  const counts = Object.create(null);

  for (const outcome of results) {
    if (outcome == null || typeof outcome !== "object") {
      throw new Error("Autobahn report contains a malformed outcome");
    }

    const classification = outcome[field];
    if (typeof classification !== "string") {
      throw new Error(`Autobahn outcome is missing ${field}`);
    }

    counts[classification] = (counts[classification] ?? 0) + 1;
  }

  return counts;
}

function verify_baseline(report, baseline) {
  const actual_ids = Object.keys(report);
  const expected_ids = [...baseline.cases.keys()];
  const missing = expected_ids.filter((case_id) =>
    !Object.hasOwn(report, case_id)
  );
  const extra = actual_ids.filter((case_id) => !baseline.cases.has(case_id));

  if (missing.length !== 0 || extra.length !== 0) {
    throw new Error(
      `Autobahn case set mismatch: missing ${describe_cases(missing)}; ` +
        `extra ${describe_cases(extra)}`,
    );
  }

  const mismatches = [];
  for (const case_id of expected_ids) {
    const actual = require_record(
      report[case_id],
      `Autobahn outcome for case ${case_id}`,
    );
    const expected = baseline.cases.get(case_id);

    for (const field of ["behavior", "behaviorClose"]) {
      if (actual[field] === expected[field]) continue;
      mismatches.push(
        `${case_id}.${field}: expected ${expected[field]}, got ${
          actual[field]
        }`,
      );
    }
  }

  if (mismatches.length !== 0) {
    throw new Error(
      `Autobahn per-case baseline mismatch: ${describe_mismatches(mismatches)}`,
    );
  }

  const results = Object.values(report);
  verify_classifications(
    "protocol",
    classification_counts(results, "behavior"),
    baseline.totals,
  );
  verify_classifications(
    "close",
    classification_counts(results, "behaviorClose"),
    baseline.totals,
  );
}

function verify_classifications(label, counts, totals) {
  const ok = counts.OK ?? 0;
  const informational = counts.INFORMATIONAL ?? 0;
  const other = Object.entries(counts)
    .filter(([name]) => name !== "OK" && name !== "INFORMATIONAL")
    .reduce((sum, [, count]) => sum + count, 0);

  if (
    ok === totals.ok &&
    informational === totals.informational &&
    other === 0
  ) return;

  throw new Error(
    `Autobahn ${label} baseline mismatch: ${describe_counts(counts)}`,
  );
}

function read_totals(value) {
  const totals = require_record(value, "Autobahn baseline totals");
  const total = read_positive_integer(totals.total, "totals.total");
  const ok = read_nonnegative_integer(totals.ok, "totals.ok");
  const informational = read_nonnegative_integer(
    totals.informational,
    "totals.informational",
  );

  if (ok + informational !== total) {
    throw new Error("Autobahn baseline totals do not add up");
  }

  return Object.freeze({ total, ok, informational });
}

function read_outcome(value, label) {
  const outcome = require_record(value, `Autobahn baseline ${label}`);
  const behavior = read_classification(outcome.behavior, `${label}.behavior`);
  const behavior_close = read_classification(
    outcome.behaviorClose,
    `${label}.behaviorClose`,
  );

  return Object.freeze({ behavior, behaviorClose: behavior_close });
}

function read_classification(value, label) {
  if (value === "OK" || value === "INFORMATIONAL") return value;
  throw new Error(`Autobahn baseline ${label} has an invalid classification`);
}

function read_positive_integer(value, label) {
  const result = read_nonnegative_integer(value, label);
  if (result !== 0) return result;
  throw new Error(`Autobahn baseline ${label} must be positive`);
}

function read_nonnegative_integer(value, label) {
  if (Number.isSafeInteger(value) && value >= 0) return value;
  throw new Error(`Autobahn baseline ${label} must be a nonnegative integer`);
}

function require_record(value, label) {
  if (value != null && typeof value === "object" && !Array.isArray(value)) {
    return value;
  }
  throw new Error(`${label} must be an object`);
}

function describe_cases(case_ids) {
  if (case_ids.length === 0) return "none";

  const limit = 12;
  const sorted = case_ids.toSorted((left, right) =>
    left.localeCompare(right, "en", { numeric: true })
  );
  const suffix = sorted.length > limit
    ? `, and ${sorted.length - limit} more`
    : "";
  return `${sorted.slice(0, limit).join(", ")}${suffix}`;
}

function describe_mismatches(mismatches) {
  const limit = 12;
  const suffix = mismatches.length > limit
    ? `; and ${mismatches.length - limit} more`
    : "";
  return `${mismatches.slice(0, limit).join("; ")}${suffix}`;
}

function describe_counts(counts) {
  return Object.entries(counts)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([name, count]) => `${count} ${name}`)
    .join(", ");
}

async function reset_reports() {
  await reset_directory(reports_directory);
}

async function reset_directory(path) {
  try {
    await Deno.remove(path, { recursive: true });
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  await Deno.mkdir(path, { recursive: true });
}

async function run_testsuite() {
  const source_config = JSON.parse(
    await Deno.readTextFile(source_config_path),
  );
  const combined_report = {};

  for (const [index, cases] of case_batches.entries()) {
    const batch_name = `batch-${index + 1}`;
    const batch_directory = `${reports_directory}/${batch_name}`;
    const config_path = `${reports_directory}/${batch_name}.json`;
    const batch_config = { ...source_config, cases };
    await Deno.writeTextFile(
      config_path,
      `${JSON.stringify(batch_config, null, 2)}\n`,
    );
    await reset_directory(batch_directory);

    const config_mount = `${config_path}:/fuzzingclient.json:ro`;
    const reports_mount = `${batch_directory}:/reports`;
    await run_batch(batch_name, batch_directory, config_mount, reports_mount);

    const batch_report_path = `${batch_directory}/servers/index.json`;
    const report = JSON.parse(await Deno.readTextFile(batch_report_path));
    const agent_report = report[agent_name];
    if (agent_report == null || typeof agent_report !== "object") {
      throw new Error(
        `Autobahn ${batch_name} report does not contain agent ${agent_name}`,
      );
    }

    for (const [case_id, result] of Object.entries(agent_report)) {
      if (Object.hasOwn(combined_report, case_id)) {
        throw new Error(`Autobahn batches repeat case ${case_id}`);
      }
      combined_report[case_id] = result;
    }
  }

  await Deno.mkdir(`${reports_directory}/servers`, { recursive: true });
  await Deno.writeTextFile(
    report_path,
    `${JSON.stringify({ [agent_name]: combined_report }, null, 2)}\n`,
  );
  return combined_report;
}

async function run_batch(
  batch_name,
  batch_directory,
  config_mount,
  reports_mount,
) {
  const maximum_attempts = 2;

  for (let attempt = 1; attempt <= maximum_attempts; attempt += 1) {
    if (attempt > 1) await reset_directory(batch_directory);

    const server = start_server();
    let status;
    try {
      await wait_for_server(server);

      const docker = new Deno.Command("docker", {
        args: [
          "run",
          "--name",
          `fuzzingserver-${batch_name}-${attempt}`,
          "--user",
          docker_user,
          "--volume",
          config_mount,
          "--volume",
          reports_mount,
          "--workdir",
          "/",
          "--net=host",
          "--rm",
          autobahn_testsuite_docker,
          "wstest",
          "-m",
          "fuzzingclient",
          "-s",
          "/fuzzingclient.json",
        ],
        cwd: test_directory,
        stdin: "null",
        stdout: "inherit",
        stderr: "inherit",
      }).spawn();
      status = await docker.status;
    } finally {
      await stop_server(server);
    }

    if (status.success) return;

    if (status.code !== 137 || attempt === maximum_attempts) {
      throw new Error(
        `Autobahn ${batch_name} container failed with ${
          describe_status(status)
        }`,
      );
    }

    console.warn(
      `Autobahn ${batch_name} container was killed; restarting the server and retrying once`,
    );
  }
}

function start_server() {
  const process = new Deno.Command(server_binary, {
    cwd: repository_directory,
    stdin: "null",
    stdout: "inherit",
    stderr: "inherit",
  }).spawn();
  const server = { process, status: null, done: null };
  server.done = process.status.then((status) => {
    server.status = status;
    return status;
  });
  return server;
}

async function wait_for_server(server) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (server.status != null) {
      throw new Error(
        `Autobahn server exited before readiness with ${
          describe_status(server.status)
        }`,
      );
    }

    try {
      const connection = await Deno.connect({
        hostname: "127.0.0.1",
        port: 9001,
      });
      connection.close();
      return;
    } catch (error) {
      if (!(error instanceof Deno.errors.ConnectionRefused)) throw error;
    }

    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  throw new Error("Autobahn server did not become ready");
}

async function stop_server(server) {
  if (server.status != null) return;

  try {
    server.process.kill("SIGTERM");
  } catch {
    // The child may have exited between the state check and the signal.
  }

  let timeout_id;
  const stopped = await Promise.race([
    server.done.then(() => true),
    new Promise((resolve) => {
      timeout_id = setTimeout(() => resolve(false), 5000);
    }),
  ]);
  clearTimeout(timeout_id);

  if (!stopped) {
    try {
      server.process.kill("SIGKILL");
    } catch {
      // The child may have exited between the timeout and the signal.
    }
  }

  await server.done;
}

function describe_status(status) {
  if (status.signal != null) return `signal ${status.signal}`;
  return `exit code ${status.code}`;
}

function container_user(file_info) {
  if (file_info.uid == null || file_info.gid == null) {
    throw new Error("Autobahn runner requires POSIX file ownership");
  }
  return `${file_info.uid}:${file_info.gid}`;
}
