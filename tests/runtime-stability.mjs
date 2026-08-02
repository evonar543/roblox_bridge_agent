import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import luaparse from "luaparse";
import { WebSocket } from "ws";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const loaderPath = path.join(repoRoot, "lua", "rba_autoloader.lua");
const autoGoalkeeperPath = path.join(repoRoot, "lua", "auto_goalkeeper_test.lua");
const autoGoalkeeperV8Path = path.join(repoRoot, "lua", "auto_goalkeeper_best_v8.lua");
const autoGoalkeeperV9Path = path.join(repoRoot, "lua", "auto_goalkeeper_best_v9.lua");
const soloPlayerPath = path.join(repoRoot, "lua", "auto_player", "auto_player_solo_v1.lua");
const chickenFarmPath = path.join(repoRoot, "lua", "chicken_farm", "egg_farm_controller.lua");
const serverPath = path.join(repoRoot, "dist", "index.js");
const loaderSource = await fs.readFile(loaderPath, "utf8");
const autoGoalkeeperSource = await fs.readFile(autoGoalkeeperPath, "utf8");
const autoGoalkeeperV8Source = await fs.readFile(autoGoalkeeperV8Path, "utf8");
const autoGoalkeeperV9Source = await fs.readFile(autoGoalkeeperV9Path, "utf8");
const soloPlayerSource = await fs.readFile(soloPlayerPath, "utf8");
const chickenFarmSource = await fs.readFile(chickenFarmPath, "utf8");

luaparse.parse(loaderSource, { luaVersion: "5.3" });
luaparse.parse(autoGoalkeeperSource, { luaVersion: "5.3" });
luaparse.parse(autoGoalkeeperV8Source, { luaVersion: "5.3" });
luaparse.parse(autoGoalkeeperV9Source, { luaVersion: "5.3" });
luaparse.parse(soloPlayerSource, { luaVersion: "5.3" });
luaparse.parse(chickenFarmSource, { luaVersion: "5.3" });
assert.match(chickenFarmSource, /__RBA_CHICKEN_FARM/, "Chicken Farm controller must own its lifecycle state");
assert.match(chickenFarmSource, /previous\.stop, "reloaded"/, "Chicken Farm reloads must stop the previous controller");
assert.match(chickenFarmSource, /RuntimeEnv\.__RBA_CHICKEN_FARM ~= state/, "Chicken Farm controller must self-stop when superseded");
assert.match(chickenFarmSource, /EXPECTED_GAME_ID/, "Chicken Farm controller must stay scoped to its authorized experience");
assert.match(chickenFarmSource, /Collect Egg/, "Chicken Farm controller must use the game's egg collection command");
assert.match(chickenFarmSource, /Deposit Eggs/, "Chicken Farm controller must use the game's deposit command");
assert.match(chickenFarmSource, /Collect Cash/, "Chicken Farm controller must use the game's cash collection command");
assert.match(chickenFarmSource, /Buy Chickens", 5/, "Chicken Farm controller must use the Buy 5 gameplay action");
assert.match(chickenFarmSource, /Rayfield:CreateWindow/, "Chicken Farm controller must use Rayfield for its UI");
assert.match(chickenFarmSource, /SiriusSoftwareLtd\/Rayfield\/main\/source\.lua/, "Chicken Farm controller must use the published Rayfield source");
assert.match(chickenFarmSource, /CreateLabel/, "Chicken Farm telemetry must use a Rayfield element supported by the executor");
assert.doesNotMatch(chickenFarmSource, /CreateButton/, "Chicken Farm UI must avoid Rayfield buttons blocked by this executor");
assert.match(chickenFarmSource, /ConfigurationSaving = \{ Enabled = false \}/, "Chicken Farm controller must avoid unsafe Rayfield state restoration in this executor");
assert.doesNotMatch(chickenFarmSource, /(?:HumanoidRootPart|character)\.CFrame\s*=/, "Chicken Farm controller must not reposition a character by CFrame");
assert.match(soloPlayerSource, /__RBA_SOLO_PLAYER/, "solo player must use its own lifecycle state");
assert.match(soloPlayerSource, /GOALKEEPER EXCLUDED/, "solo player must never run goalkeeper behavior");
assert.match(soloPlayerSource, /ActionSecondary\.start/, "solo player must use the normal pass action");
assert.match(soloPlayerSource, /ActionPrimary\.start/, "solo player must use the normal kick action");
assert.match(soloPlayerSource, /Dribble\.Activate/, "solo player must use the normal dribble action");
assert.match(soloPlayerSource, /humanoid:MoveTo/, "solo player movement must use normal Humanoid movement");
assert.doesNotMatch(soloPlayerSource, /(?:HumanoidRootPart|character)\.CFrame\s*=/, "solo player must not reposition a character by CFrame");
assert.match(soloPlayerSource, /MoveLine/, "solo player must expose a movement visualizer line");
assert.match(soloPlayerSource, /PassLine/, "solo player must expose a pass visualizer line");
assert.match(soloPlayerSource, /ShotLine/, "solo player must expose a shot visualizer line");
assert.match(soloPlayerSource, /PASS_AIM_ALIGNMENT/, "solo player must require natural camera alignment before passing");
assert.match(soloPlayerSource, /SHOT_AIM_ALIGNMENT/, "solo player must require natural camera alignment before shooting");
assert.match(soloPlayerSource, /PossessorId/, "solo player must resolve the game's ball holder identity");
assert.match(soloPlayerSource, /AgentId/, "solo player must map a PossessorId back to a live player");
assert.match(soloPlayerSource, /BALL_VERTICAL_TOLERANCE/, "solo player must ignore hidden off-pitch ball positions");
assert.match(soloPlayerSource, /cut off ball carrier/, "solo player must press the holder instead of a hidden ball");
assert.match(soloPlayerSource, /RequestBall\.Activate/, "solo player must use the normal pass-request controller");
assert.match(soloPlayerSource, /Tackle\.Activate/, "solo player must use the normal tackle controller");
assert.match(soloPlayerSource, /getInterceptTarget/, "solo player must lead moving loose balls instead of only chasing them");
assert.match(soloPlayerSource, /estimatePursuitSpeed/, "intercepts must use the player's expected live movement speed");
assert.match(soloPlayerSource, /timeToReach/, "path scoring must include arrival time");
assert.match(soloPlayerSource, /arrivalSpace/, "path scoring must include future space around the destination");
assert.match(soloPlayerSource, /LIVE_UPDATE_HZ/, "short-fuse interceptions must receive a live decision rate");
assert.match(soloPlayerSource, /REALTIME_MOVE_HZ/, "urgent paths must issue movement commands more frequently");
assert.match(soloPlayerSource, /open for teammate/, "solo player must create an open support lane for a teammate");
assert.match(soloPlayerSource, /plan\.hasBall/, "solo player actions must honor resolved local possession");
assert.match(soloPlayerSource, /STEAL_AIM_ALIGNMENT/, "automatic tackles must require a safe facing alignment");
assert.match(soloPlayerSource, /autoAim/, "solo player must expose opt-in camera aim assistance");
assert.match(soloPlayerSource, /turnCameraToward/, "solo player must turn toward the selected tactical target");
assert.match(soloPlayerSource, /RunService:BindToRenderStep/, "camera turning must update smoothly after Roblox updates its camera");
assert.match(soloPlayerSource, /camera\.CFrame = camera\.CFrame:Lerp/, "camera aiming must interpolate instead of snapping");
assert.match(soloPlayerSource, /goalkeeper protected/, "solo player must never tackle a goalkeeper");
assert.match(soloPlayerSource, /block goalkeeper outlet/, "goalkeeper possession must become outlet blocking, not a steal attempt");
assert.match(soloPlayerSource, /side == "Home" or side == "Away"/, "field awareness must exclude non-team players");
assert.match(soloPlayerSource, /sharedStateValue\("Match"/, "solo player must read match-state gates");
assert.match(soloPlayerSource, /getSpecialAnimation/, "solo player must inspect playing animations before actions");
assert.match(soloPlayerSource, /GK_REQUEST_MIN_PROGRESS/, "goalkeeper pass requests must require advanced field position");
assert.match(soloPlayerSource, /GK_REQUEST_MIN_CLEARANCE/, "goalkeeper pass requests must require a clear lane");
assert.match(soloPlayerSource, /chooseSupportTarget/, "solo player must build team-aware support lanes");
assert.match(soloPlayerSource, /THREAT_UPDATE_HZ/, "solo player must react faster to threats than idle play");
assert.match(soloPlayerSource, /ACTION_STAMINA_MIN/, "solo player must reserve stamina for actions");
assert.match(soloPlayerSource, /chargeForTarget/, "solo player must calculate charge from ball physics ranges");
assert.match(soloPlayerSource, /chargeForShot/, "close and long shots must use a dedicated finishing power curve");
assert.match(soloPlayerSource, /closeFinish and 78/, "close finishes must receive enough normal kick charge");
assert.match(soloPlayerSource, /FootballDefaults\.Velocity\.Pass/, "pass power must use the game's pass velocity range");
assert.match(soloPlayerSource, /FootballDefaults\.Velocity\.Kick/, "kick power must use the game's kick velocity range");
assert.match(soloPlayerSource, /FootballDefaults\.ChargeTimes\.Pass/, "normal click-kicks must use the game's normal charge window");
assert.match(soloPlayerSource, /undercharged normal shots/, "the controller must document why normal kick timing differs from PowerShot timing");
assert.match(soloPlayerSource, /targetPressure/, "pass selection must account for receiver pressure");
assert.match(soloPlayerSource, /STEAL_APPROACH_LEAD/, "pressing must lead moving ball carriers");
assert.match(soloPlayerSource, /STEAL_APPROACH_DISTANCE/, "pressing must close to a normal slide-tackle approach range");
assert.match(soloPlayerSource, /cut off ball carrier/, "pressing must target an interception point, not trail behind");
assert.match(soloPlayerSource, /predict carrier cutoff/, "pressing must predict a moving carrier's future position");
assert.match(soloPlayerSource, /POSSESSION_SETTLE_SECONDS/, "new possession must settle before a risky action");
assert.match(soloPlayerSource, /chooseRetentionTarget/, "under-pressure ball retention must choose safe escape routes");
assert.match(soloPlayerSource, /SAFE_PASS_CLEARANCE/, "passing must require a safe lane");
assert.match(soloPlayerSource, /PREFERRED_SHOOT_RANGE/, "shots must be weighed against progressive passes");
assert.match(soloPlayerSource, /PrepareShot\.CancelPreparedShot/, "prepared actions must cancel when possession changes");
assert.match(soloPlayerSource, /updatePossessionState/, "the controller must track possession transitions");
assert.match(soloPlayerSource, /assessHoldRisk/, "the controller must estimate when ball retention is failing");
assert.match(soloPlayerSource, /HOLD_RISK_RELEASE_THRESHOLD/, "imminent pressure must trigger a release decision");
assert.match(soloPlayerSource, /HOLD_RISK_SHIELD_THRESHOLD/, "moderate pressure must trigger a shield decision");
assert.match(soloPlayerSource, /safe release before tackle/, "the bot must release before losing the ball when an outlet exists");
assert.match(soloPlayerSource, /imminent tackle risk/, "hold-risk diagnostics must expose why it is releasing");
assert.match(soloPlayerSource, /CONTEST_RADIUS/, "retention must account for multiple nearby defenders");
assert.match(soloPlayerSource, /turnoverDeadline/, "retention must estimate time before a defender reaches the ball");
assert.match(soloPlayerSource, /EMERGENCY_RELEASE_DEADLINE/, "critical pressure must get an emergency decision window");
assert.match(soloPlayerSource, /CRITICAL_UPDATE_HZ/, "critical retention decisions must run faster than normal play");
assert.match(soloPlayerSource, /getPassTarget/, "passes must lead a moving receiver");
assert.match(soloPlayerSource, /RECEIVER_LEAD_LIMIT/, "receiver lead must be bounded");
assert.match(soloPlayerSource, /isConfirmedPassTarget/, "passes must revalidate their intended teammate");
assert.match(soloPlayerSource, /target team changed/, "a target that switches teams must block the pass");
assert.match(soloPlayerSource, /target identity changed/, "a reused target identity must block the pass");
assert.match(soloPlayerSource, /passRejects/, "pass-target rejections must be visible in telemetry");
assert.match(soloPlayerSource, /adaptiveRiskBias/, "confirmed release outcomes must tune future retention risk");
assert.match(soloPlayerSource, /emergency safe release/, "the bot must expose emergency outlet decisions");
assert.match(soloPlayerSource, /pendingPossessionOutcome/, "direct losses while holding the ball must be tracked after the ball is loose");
assert.match(soloPlayerSource, /EMERGENCY_PASS_AIM_ALIGNMENT/, "emergency outlets must not wait for a full-turn camera alignment");
assert.match(soloPlayerSource, /CLOSE_SHOOT_RANGE/, "close goal opportunities must be scored before a conservative pass decision");
assert.match(soloPlayerSource, /CLOSE_SHOT_AIM_ALIGNMENT/, "close finishes must not wait for an unnecessary full-turn alignment");
assert.match(soloPlayerSource, /LONG_SHOT_MIN_CLEARANCE/, "speculative long shots must require a clearly open lane");
assert.match(soloPlayerSource, /GOALKEEPER_AVOID_RADIUS/, "shot targeting must prefer the side away from the goalkeeper");
assert.match(soloPlayerSource, /goalkeeperSeparation/, "shot scoring must model goalkeeper position");
assert.match(soloPlayerSource, /rightAxis/, "shot targeting must follow the actual goal mouth orientation");
assert.match(soloPlayerSource, /halfWidth/, "shot targeting must use real goal dimensions");
assert.match(soloPlayerSource, /QUICK_FINISH_SETTLE_SECONDS/, "a new close possession must be able to finish before the chance expires");
assert.match(soloPlayerSource, /PREEMPTIVE_DRIBBLE_DISTANCE/, "approaching defenders must trigger an early dribble route");
assert.match(soloPlayerSource, /predictedBall/, "the controller must expose a projected loose-ball trajectory");
assert.match(soloPlayerSource, /predictionSeconds/, "passing and path lanes must account for moving defenders");
assert.match(soloPlayerSource, /assistMode/, "manual movement assist mode must keep tactical actions available");
assert.match(soloPlayerSource, /BallTrajectoryLine/, "the GUI must visualize the predicted ball path");
assert.match(soloPlayerSource, /ThreatLine/, "the GUI must clearly visualize incoming pressure");
assert.match(soloPlayerSource, /isWallPathBlocked/, "passes and runs must inspect the real field barriers");
assert.match(soloPlayerSource, /Field.*Barriers|field:FindFirstChild\("Barriers"\)/, "wall checks must use the stadium field barrier geometry");
assert.match(soloPlayerSource, /chooseSelfPass/, "the controller must identify a wall-safe self-pass lane");
assert.match(soloPlayerSource, /SELF_PASS/, "the controller must execute a self-pass through the normal kick action");
assert.match(soloPlayerSource, /autoSelfPass/, "self-passing must be independently configurable");
assert.match(autoGoalkeeperV8Source, /version = 8/, "named goalkeeper snapshot must remain v8");
assert.match(
  autoGoalkeeperV8Source,
  /BEST MODE: ON/,
  "named v8 goalkeeper snapshot must include BEST MODE"
);
assert.match(autoGoalkeeperV9Source, /version = 9/, "named goalkeeper upgrade must expose v9");
assert.match(autoGoalkeeperV9Source, /autoJump/, "v9 must expose a jump mode");
assert.match(autoGoalkeeperV9Source, /UpdateJumpingState\(true\)/, "v9 must use the normal movement-controller jump gate");
assert.match(autoGoalkeeperV9Source, /HumanoidStateType\.Jumping/, "v9 must verify the Humanoid entered a jump");
assert.match(autoGoalkeeperV9Source, /JUMP_HORIZONTAL_TOLERANCE/, "v9 jumps must stay limited to central saves");
assert.match(autoGoalkeeperV9Source, /JUMP_MIN_HEIGHT_GAP/, "v9 must only jump for above-standing-reach shots");
assert.match(autoGoalkeeperV9Source, /isAirborne/, "v9 must halt walking while airborne");
assert.doesNotMatch(autoGoalkeeperV9Source, /(?:CFrame|PivotTo)\s*=/, "v9 must not reposition by assigning a transform");
assert.match(loaderSource, /__RBA_LOADER_STATE/, "loader must expose its single-instance lifecycle state");
assert.match(loaderSource, /MAX_QUEUED_EVALS/, "loader must bound its execution queue");
assert.match(loaderSource, /MAX_QUEUED_BYTES/, "loader must bound queued source memory");
assert.match(loaderSource, /MAX_INCOMING_BYTES/, "loader must enforce an incoming payload limit");
assert.match(loaderSource, /__RBA_INSTANCE_MANAGER_STATE/, "unified loader must guard the Instance Manager connector");
assert.match(loaderSource, /localhost:16384/, "unified loader must default to the local Instance Manager bridge");
assert.match(loaderSource, /duplicateRequestProtection/, "loader must reject duplicate eval request identifiers");
assert.match(loaderSource, /execution_timeout/, "loader must time out stalled evaluation workers");
assert.match(autoGoalkeeperSource, /VelocityDampening/, "goalkeeper predictor must model the game's ball damping");
assert.match(autoGoalkeeperSource, /Leap\.Activate/, "goalkeeper controller must use the normal in-game dive action");
assert.match(autoGoalkeeperSource, /BEST MODE: ON/, "goalkeeper GUI must expose the coordinated best mode");
assert.match(autoGoalkeeperSource, /PING_COMPENSATION_FACTOR/, "best mode must account for measured network delay");
assert.match(autoGoalkeeperSource, /GetServerTimeNow/, "release prediction must use synchronized server time");
assert.match(autoGoalkeeperSource, /ReleasePosition/, "predictor must reconstruct newly released balls from release position");
assert.match(autoGoalkeeperSource, /ReleaseVelocity/, "predictor must reconstruct newly released balls from release velocity");
assert.match(autoGoalkeeperSource, /LastReleaseTime/, "release reconstruction must be advanced by release age");
assert.match(autoGoalkeeperSource, /getEffectiveBallGravity/, "predictor must derive effective ball gravity");
assert.match(autoGoalkeeperSource, /descendant:IsA\("VectorForce"\)/, "effective gravity must include enabled ball forces");
assert.match(autoGoalkeeperSource, /effectiveSaveDistance/, "commit timing must account for keeper and ball capture radius");
assert.match(autoGoalkeeperSource, /Sprint\.Activate/, "long goalkeeper positioning moves must use normal sprint controls");
assert.match(autoGoalkeeperSource, /Enum\.KeyCode\.LeftShift/, "automatic sprint release must preserve manually held Left Shift");
assert.match(
  autoGoalkeeperSource,
  /MovementController:SetSprintingControlState\(false\)/,
  "automatic sprint must release through the normal movement controller"
);
assert.match(autoGoalkeeperSource, /GetAttribute\("AgentId"\)/, "possession checks must use the game's AgentId identity");
assert.match(autoGoalkeeperSource, /pcall\(previous\.stop, "reloaded"\)/, "goalkeeper reload must stop the previous controller");
assert.doesNotMatch(autoGoalkeeperSource, /test window expired/, "goalkeeper must not have an automatic test timer");
assert.match(autoGoalkeeperSource, /RBAAutoGoalkeeperGui/, "goalkeeper test must expose its live telemetry GUI");
assert.match(autoGoalkeeperSource, /AUTO DIVE: ON/, "goalkeeper GUI must expose its auto-dive mode");
assert.match(autoGoalkeeperSource, /WALK: ON/, "goalkeeper GUI must expose normal movement assist");
assert.match(autoGoalkeeperSource, /AUTO CLEAR: ON/, "goalkeeper GUI must expose automatic clearing");
assert.match(autoGoalkeeperSource, /humanoid:MoveTo/, "goalkeeper movement must use normal Humanoid movement");
assert.doesNotMatch(autoGoalkeeperSource, /humanoid\.Health\s*[<>]=?\s*0/, "custom football humanoids must not be rejected by Health");
assert.doesNotMatch(autoGoalkeeperSource, /(?:CFrame|PivotTo)\s*=/, "goalkeeper must not reposition by assigning a transform");
assert.match(autoGoalkeeperSource, /ActionPrimary\.start/, "automatic clear must use the normal primary action");
assert.match(autoGoalkeeperSource, /ActionPrimary\.release/, "automatic clear must release the normal primary action");
assert.match(autoGoalkeeperSource, /model_calibrated/, "goalkeeper must expose adaptive prediction calibration");
assert.match(autoGoalkeeperSource, /failedSaves/, "goalkeeper must learn from failed attempted saves");
assert.match(autoGoalkeeperSource, /shot_discarded/, "goalkeeper must reject implausible recycled-ball samples");
assert.match(autoGoalkeeperSource, /DEFENSIVE_TRACK_DISTANCE/, "goalkeeper must center instead of chasing far balls");
assert.match(autoGoalkeeperSource, /DIVE RETRY ARMED/, "goalkeeper must recover from an unconfirmed first dive");
assert.match(autoGoalkeeperSource, /MAX_DIVE_ATTEMPTS_PER_SHOT/, "goalkeeper dive retries must remain bounded");
assert.match(autoGoalkeeperSource, /InterceptLine/, "goalkeeper GUI must draw its keeper-to-intercept line");
assert.match(autoGoalkeeperSource, /RawPrediction/, "goalkeeper GUI must distinguish raw and corrected predictions");
assert.match(autoGoalkeeperSource, /TrackState/, "idle goal display must explain why no intercept is shown");
assert.match(autoGoalkeeperSource, /goalDisplayHealth/, "goalkeeper must expose goal-display diagnostics");
assert.match(autoGoalkeeperSource, /mapGoalPoint/, "goalkeeper display must share one bounded 2D goal mapper");
assert.match(autoGoalkeeperSource, /prediction\.confidence/, "goalkeeper must expose prediction confidence");
assert.match(autoGoalkeeperSource, /STOP TEST/, "goalkeeper GUI must expose a bounded stop control");

const effectiveGravity = 196.2 - 55 / 0.6434;
assert.ok(
  effectiveGravity > 110 && effectiveGravity < 112,
  "the observed football force should produce roughly 111 studs/s^2 of effective gravity"
);

const updateHz = 30;
const pingSeconds = 0.332;
const jitterSeconds = 0.01;
const networkCompensation = Math.min(
  0.35,
  pingSeconds * 0.5 + jitterSeconds + 2 / updateHz
);
const commitLead = (effectiveDistance) => {
  const travelSeconds = Math.min(0.7, Math.max(0.08, effectiveDistance / 30));
  return travelSeconds + networkCompensation + 0.02;
};
assert.ok(commitLead(18) > commitLead(2), "far saves must commit earlier than near saves");
assert.ok(commitLead(2) < 0.5, "central saves must not inherit the old one-second fixed trigger");
assert.ok(commitLead(18) < 1, "ping compensation must remain bounded for reachable saves");

const testRoot = await fs.mkdtemp(path.join(tmpdir(), "rba-runtime-stability-"));
const potassiumTarget = path.join(testRoot, "Potassium", "autoexec", "rba_autoloader.lua");
const voltTarget = path.join(testRoot, "Volt", "autoexec", "rba_autoloader.lua");
const resolvedTempRoot = `${path.resolve(tmpdir())}${path.sep}`.toLowerCase();
assert.ok(
  `${path.resolve(testRoot)}${path.sep}`.toLowerCase().startsWith(resolvedTempRoot),
  "test directory must remain inside the system temporary directory"
);

let child;
let stderr = "";

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForConnectionState(timeoutMs = 10_000) {
  const statePath = path.join(testRoot, "rba-connection.json");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child?.exitCode !== null) {
      throw new Error(`RBA test server exited early with code ${child?.exitCode}.\n${stderr}`);
    }
    try {
      const state = JSON.parse(await fs.readFile(statePath, "utf8"));
      if (typeof state.url === "string" && state.url.startsWith("ws://") && state.port > 0) {
        return state;
      }
    } catch {
      // The state file is published atomically after the websocket starts.
    }
    await delay(50);
  }
  throw new Error(`Timed out waiting for the RBA test server.\n${stderr}`);
}

async function waitForFile(filePath, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await fs.access(filePath);
      return;
    } catch {
      if (child?.exitCode !== null) {
        throw new Error(`RBA test server exited before syncing ${filePath}.\n${stderr}`);
      }
      await delay(50);
    }
  }
  throw new Error(`Timed out waiting for synced file ${filePath}.\n${stderr}`);
}

async function openSocket(url) {
  const socket = new WebSocket(url);
  const opened = once(socket, "open");
  const failed = once(socket, "error").then(([error]) => {
    throw error;
  });
  await Promise.race([opened, failed]);
  return socket;
}

try {
  await fs.mkdir(path.join(testRoot, "lua"), { recursive: true });
  await fs.copyFile(loaderPath, path.join(testRoot, "lua", "rba_autoloader.lua"));
  await fs.writeFile(
    path.join(testRoot, "rba-profiles.json"),
    `${JSON.stringify({ version: 1, profiles: {} }, null, 2)}\n`,
    "utf8"
  );

  child = spawn(process.execPath, [serverPath], {
    cwd: repoRoot,
    windowsHide: true,
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      RBA_ROOT: testRoot,
      RBA_AUTO_START_WS: "true",
      RBA_SYNC_AUTOEXEC: "true",
      RBA_AUTOEXEC_INCLUDE_DEFAULTS: "false",
      RBA_AUTOEXEC_PATHS: `${potassiumTarget};${voltTarget}`,
      RBA_WS_HOST: "127.0.0.1",
      RBA_WS_PORT: "0",
      RBA_WS_MAX_PAYLOAD_BYTES: "1048576"
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.length > 16_384) {
      stderr = stderr.slice(-16_384);
    }
  });

  const state = await waitForConnectionState();
  await Promise.all([
    waitForFile(potassiumTarget),
    waitForFile(voltTarget)
  ]);
  const syncedSource = await fs.readFile(path.join(testRoot, "lua", "rba_autoloader.lua"));
  assert.deepEqual(await fs.readFile(potassiumTarget), syncedSource, "Potassium target must match the source loader");
  assert.deepEqual(await fs.readFile(voltTarget), syncedSource, "Volt target must match the source loader");

  const normal = await openSocket(state.url);
  normal.send(JSON.stringify({
    type: "hello",
    capabilities: { protocol: 4, boundedExecutionQueue: true, unifiedRuntime: true },
    name: "runtime-stability-test"
  }));
  normal.send(JSON.stringify({
    type: "client_heartbeat",
    version: "test",
    queue: { waiting: 0, active: 0, dropped: 0 }
  }));
  await delay(75);
  assert.equal(normal.readyState, WebSocket.OPEN, "normal protocol traffic should keep the socket open");
  normal.close(1000, "normal test complete");
  await once(normal, "close");

  const oversized = await openSocket(state.url);
  oversized.on("error", () => {
    // A protocol-level close can surface as an error on some ws/Windows combinations.
  });
  const oversizedClosed = once(oversized, "close");
  oversized.send(Buffer.alloc(1_048_577, 0x61));
  await Promise.race([
    oversizedClosed,
    delay(5000).then(() => {
      throw new Error("oversized websocket frame was not rejected");
    })
  ]);

  const recovered = await openSocket(state.url);
  recovered.send(JSON.stringify({
    type: "hello",
    capabilities: { protocol: 4 },
    name: "post-rejection-health-test"
  }));
  await delay(75);
  assert.equal(recovered.readyState, WebSocket.OPEN, "server should remain healthy after rejecting an oversized client");
  recovered.close(1000, "recovery test complete");
  await once(recovered, "close");

  console.log("Runtime stability checks passed.");
} finally {
  if (child && child.exitCode === null) {
    child.kill();
    await Promise.race([once(child, "exit"), delay(3000)]);
  }
  await fs.rm(testRoot, { recursive: true, force: true });
}
