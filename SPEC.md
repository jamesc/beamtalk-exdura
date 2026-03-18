# Exdura — Durable Workflow Engine Specification

Status: Draft v1 (Beamtalk reference implementation)

Purpose: Define a durable execution engine for long-running workflows on the BEAM, inspired by
Temporal's programming model but built natively on OTP primitives.

Exdura is first and foremost a **Beamtalk language exercise**. The domain (durable workflows) is
chosen because it stresses language features that Symphony (the first Beamtalk application) did not:
deep inheritance hierarchies, actor pools, complex error handling with compensation, ETF
serialization, dynamic dispatch, and OTP supervision depth. Production readiness is a secondary,
future goal — v1 prioritizes proving that Beamtalk can express a complex, real-world system
correctly.

## 1. Problem Statement

Many business processes are long-running, stateful, and must survive failures: order fulfillment,
CI/CD pipelines, data processing, multi-step integrations, approval flows. These are typically
implemented as fragile state machines glued together with queues, databases, and retry logic.

Temporal proved that a better abstraction exists: write workflows as ordinary sequential code, and
let the runtime handle persistence, retries, and failure recovery transparently.

Exdura brings this model to the BEAM. Each workflow is an Actor. Each activity is a supervised task.
State is persisted as an event log and replayed on recovery. The BEAM provides lightweight processes,
supervision, distribution, and hot code reload — things Temporal rebuilds from scratch in Go.

Exdura solves four problems:

- It lets developers write complex multi-step business logic as sequential Beamtalk code rather than
  state machines, callbacks, or queue consumers.
- It makes workflow state durable — workflows survive process crashes, node restarts, and
  deployments through event-sourced replay.
- It provides visibility into running and completed workflows through queries and a searchable
  history.
- It handles retries, timeouts, cancellation, and compensation as first-class primitives rather than
  application-level concerns.

Important boundary:

- Exdura is a workflow runtime, not an application framework.
- Business logic lives in workflow and activity code, not in Exdura's internals.
- Exdura does not prescribe how activities communicate with external systems.

## 2. Goals and Non-Goals

### 2.1 Goals

- Execute workflows as durable, replayable Actor processes.
- Persist workflow state as an append-only event log.
- Replay event history to recover workflow state after crashes.
- Execute activities in supervised worker pools with configurable retries and timeouts.
- Support signals (external events sent to running workflows).
- Support queries (synchronous reads of workflow state without side effects).
- Support child workflows with configurable parent-close policies.
- Support durable timers that survive process restarts.
- Support saga/compensation patterns for rollback on failure.
- Provide a client API for starting, signalling, querying, and cancelling workflows.
- Leverage OTP supervision and hot code reload (for activity classes; workflow classes use
  versioning — see §6.4).
- Expose structured observability (logs, metrics, workflow history).

### 2.2 Non-Goals

- Multi-node distribution (v1 targets a single BEAM node; multi-node clustering is future work once
  Beamtalk's distribution story is proven).
- Full compatibility with Temporal's gRPC protocol or client libraries.
- General-purpose job queue (use Oban, Exq, etc.).
- Prescribing specific persistence backends beyond the defined storage interface.
- Web UI (v1 targets API and CLI visibility; UI is a future layer).

## 3. System Overview

### 3.1 Core Concepts

#### Workflow

A Workflow is a durable, long-running function that orchestrates Activities and other Workflows.
Workflows are deterministic — given the same event history, they produce the same sequence of
commands. Workflows are implemented as Beamtalk Actor subclasses.

A Workflow's code runs in a Workflow Actor process. State mutations are recorded as events. On
recovery, the runtime replays events to reconstruct the Actor's state without re-executing side
effects.

#### Activity

An Activity is a single unit of work that may have side effects: calling an API, writing to a
database, sending an email. Activities are non-deterministic and are executed by Activity Workers.
Activity results are recorded in the workflow's event history.

Activities are implemented as class methods on Activity classes. They execute in a supervised worker
pool, separate from the Workflow Actor.

#### Event History

Every workflow has an append-only event log. Events record:
- Workflow started/completed/failed/cancelled/timed out.
- Activity scheduled/started/completed/failed/timed out.
- Timer started/fired/cancelled.
- Signal received.
- Child workflow started/completed/failed.
- Workflow state snapshots (periodic, for replay optimization).

The event history is the source of truth. Workflow code is re-executed against the history during
replay; activities are not re-executed — their recorded results are returned instead.

#### Task Queue

A named queue that routes workflow tasks and activity tasks to workers. Workers poll task queues for
work. Multiple workers can listen on the same task queue for load distribution.

#### Signal

An external asynchronous message sent to a running workflow. Signals can carry data and trigger
state transitions or unblock waiting workflows. Signals are recorded in the event history.

Signals are not delivered directly to the Workflow Actor. They are sent to the Workflow Engine,
which buffers them and delivers them at **safe points** — between workflow commands (after an
activity completes, a timer fires, etc.). This avoids the problem of the Workflow Actor being
blocked in a synchronous call when a signal arrives. See §6.5 for the full delivery model.

#### Query

A synchronous, read-only request to inspect workflow state. Queries are handled by the Workflow
Engine, not the Workflow Actor directly. The Engine maintains a cached snapshot of each workflow's
state (updated after each safe point) and evaluates registered query handlers against this snapshot.

This means queries see state as of the last completed workflow command, not the in-progress state.
Query handlers should be pure — no side effects, no activity calls. This is a convention enforced
by documentation and testing, not a runtime guarantee (Beamtalk has no purity checking).

#### Timer

A durable delay. `Workflow sleep: duration` creates a timer event in the history. If the workflow
process crashes and replays, the timer fires at the correct wall-clock time relative to when it was
originally created.

#### Child Workflow

A workflow started by another workflow. Child workflows have their own event history and can outlive
or be terminated with their parent, depending on the parent-close policy.

### 3.2 Main Components

1. **Workflow Engine**
   - Manages workflow lifecycle (create, replay, signal, query, cancel).
   - Routes tasks to workers via task queues.
   - Persists events to the Event Store.

2. **Workflow Worker**
   - Polls a task queue for workflow tasks.
   - Executes workflow code in a Workflow Actor.
   - Workflow API methods (`runActivity:with:`, `sleep:`, `startChildWorkflow:`, etc.) are
     synchronous calls that block the Actor process until a result is available. During replay,
     these methods return cached results from the event history. See §6.5 for details.

3. **Activity Worker**
   - Polls a task queue for activity tasks.
   - Executes activity code in supervised processes.
   - Reports results (or failures) back to the engine.
   - Supports heartbeating for long-running activities.

4. **Event Store**
   - Append-only persistent storage for workflow event histories.
   - Supports read, append, and snapshot operations.
   - v1 backend: ETS (in-memory) + append-only file (on-disk), with a pluggable storage interface
     for future backends (Khepri, PostgreSQL, etc.).

5. **Client**
   - API for external code to interact with workflows.
   - Start, signal, query, cancel, and list workflows.
   - Synchronous (wait for result) and asynchronous (fire-and-forget) modes.

6. **Scheduler** (optional)
   - Cron-like scheduling for recurring workflows.
   - Persists schedule state for crash recovery.

7. **Visibility Store** (optional)
   - Searchable index of workflow executions.
   - Supports filtering by workflow type, status, start time, custom search attributes.

### 3.3 Architecture Diagram

```
                    ┌─────────────────────────────────┐
                    │           Client API             │
                    │   start / signal / query / cancel│
                    └──────────────┬──────────────────┘
                                   │
                    ┌──────────────▼──────────────────┐
                    │        Workflow Engine           │
                    │   (Supervisor + Router Actor)    │
                    └───┬──────────────┬──────────────┘
                        │              │
           ┌────────────▼───┐   ┌──────▼────────────┐
           │ Workflow Workers│   │ Activity Workers   │
           │ (Actor per WF) │   │ (Supervised Pool)  │
           └────────┬───────┘   └──────┬─────────────┘
                    │                  │
           ┌────────▼──────────────────▼──────────────┐
           │            Event Store                    │
           │   (ETS + file / Khepri / pluggable)       │
           └──────────────────────────────────────────┘
```

### 3.4 External Dependencies

- BEAM/OTP runtime (OTP 27+ / Beamtalk).
- ETS (built-in) for in-memory workflow state; append-only file for on-disk event persistence.
- Optional (future): Khepri for multi-node persistence, PostgreSQL for production deployments.
- Optional: HTTP server for client API (REST/JSON).

### 3.5 Serialization

All data that crosses a persistence boundary — event payloads, activity arguments and results,
workflow state snapshots, signal payloads — is serialized using **Erlang Term Format (ETF)** via
`term_to_binary` / `binary_to_term`. ETF is the native BEAM serialization format, requires no
external dependencies, and handles all standard Beamtalk types (integers, floats, strings, symbols,
lists, dictionaries, tuples, `Value` subclasses).

JSON serialization is used only at the optional HTTP API boundary (§7.2) for external clients.

**Prohibited in persisted positions:**

- **Blocks (closures)** — capture lexical environments containing Pids and module references that
  cannot survive process or node restarts.
- **Raw Pids / Actor references** — invalid after the owning process terminates or the node
  restarts. Use workflow IDs or string identifiers instead.
- **Arbitrary `Object` subclasses with mutable state** — no guaranteed round-trip serialization.
  Use `Value` subclasses (immutable, auto-generated constructors) or plain dictionaries.

The Workflow base class enforces these constraints at the `runActivity:with:` and state snapshot
boundaries by validating that arguments and return values are ETF-serializable.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 WorkflowExecution

A single execution of a workflow.

Fields:
- `workflow_id` (string) — Caller-assigned or auto-generated unique identifier.
- `run_id` (string) — Unique per-attempt identifier (new on each retry/continue-as-new).
- `workflow_type` (string) — Class name of the Workflow Actor.
- `task_queue` (string) — Task queue this workflow is assigned to.
- `args` (list) — Arguments passed to the workflow start method.
- `status` (enum: `running`, `completed`, `failed`, `cancelled`, `timed_out`, `continued_as_new`).
- `result` (any, nullable) — Return value on completion.
- `error` (map, nullable) — Failure info on error.
- `parent_workflow_id` (string, nullable) — If this is a child workflow.
- `started_at` (timestamp).
- `closed_at` (timestamp, nullable).
- `search_attributes` (map) — Custom searchable metadata.

#### 4.1.2 Event

A single entry in a workflow's event history.

Fields:
- `event_id` (integer) — Monotonically increasing sequence number within the workflow.
- `event_type` (enum) — See Section 4.2.
- `timestamp` (timestamp).
- `payload` (map) — Event-type-specific data.

#### 4.1.3 ActivityTask

A unit of work dispatched to an Activity Worker.

Fields:
- `task_id` (string).
- `workflow_id` (string).
- `activity_type` (string) — Class + method name.
- `args` (list).
- `task_queue` (string).
- `retry_policy` (RetryPolicy).
- `timeout_config` (TimeoutConfig).
- `heartbeat_timeout` (duration, nullable).
- `attempt` (integer) — Current attempt number (1-based).

#### 4.1.4 RetryPolicy

Fields:
- `initial_interval` (duration) — Default: 1 second.
- `backoff_coefficient` (float) — Default: 2.0.
- `maximum_interval` (duration, nullable) — Cap on backoff. Default: 100x initial.
- `maximum_attempts` (integer, nullable) — 0 or null means unlimited.
- `non_retryable_errors` (list of strings) — Error types that should not be retried.

#### 4.1.5 TimeoutConfig

Fields:
- `workflow_execution_timeout` (duration, nullable) — Total time for workflow including retries.
- `workflow_run_timeout` (duration, nullable) — Time for a single workflow run.
- `schedule_to_close_timeout` (duration, nullable) — Total time for activity from schedule to close.
- `start_to_close_timeout` (duration, nullable) — Time from worker pickup to completion.
- `schedule_to_start_timeout` (duration, nullable) — Time waiting in task queue.
- `heartbeat_timeout` (duration, nullable) — Maximum gap between heartbeats.

#### 4.1.6 Signal

Fields:
- `signal_name` (string) — Named channel for the signal.
- `payload` (any) — Signal data.
- `timestamp` (timestamp).

### 4.2 Event Types

Workflow lifecycle:
- `WorkflowStarted` — Workflow execution created.
- `WorkflowCompleted` — Workflow returned a result.
- `WorkflowFailed` — Workflow threw an unhandled error.
- `WorkflowCancelled` — Workflow cancelled by client or parent.
- `WorkflowTimedOut` — Workflow exceeded execution timeout.
- `WorkflowContinuedAsNew` — Workflow restarted with new args and fresh history.

Activity lifecycle:
- `ActivityScheduled` — Workflow requested an activity execution.
- `ActivityStarted` — Worker picked up the activity task.
- `ActivityCompleted` — Activity returned a result.
- `ActivityFailed` — Activity threw an error (may retry).
- `ActivityTimedOut` — Activity exceeded timeout.
- `ActivityCancelled` — Activity cancelled.
- `ActivityHeartbeat` — Heartbeat received from activity.

Timer lifecycle:
- `TimerStarted` — Durable timer created.
- `TimerFired` — Timer duration elapsed.
- `TimerCancelled` — Timer cancelled before firing.

Signal lifecycle:
- `SignalReceived` — External signal delivered to workflow.

Child workflow lifecycle:
- `ChildWorkflowStarted` — Child workflow execution created.
- `ChildWorkflowCompleted` — Child workflow returned a result.
- `ChildWorkflowFailed` — Child workflow failed.
- `ChildWorkflowCancelled` — Child workflow cancelled.

Snapshot:
- `StateSnapshot` — Periodic checkpoint of workflow state for replay optimization.

## 5. Workflow Programming Model

### 5.1 Defining a Workflow

Workflows are Actor subclasses that extend `Workflow`:

```beamtalk
Workflow subclass: OrderWorkflow
  state: orderId :: String
  state: status :: String = "pending"
  state: items :: List = #()

  /// Entry point — called when workflow starts.
  run: orderId :: String items: items :: List -> Dictionary =>
    self.orderId := orderId
    self.items := items

    // Step 1: Reserve inventory (activity)
    reservation := self runActivity: OrderActivities >> #reserveInventory:
      with: #{#orderId => orderId, #items => items}
      options: #{#startToCloseTimeout => 30000}

    // Step 2: Charge payment (activity)
    payment := self runActivity: OrderActivities >> #chargePayment:
      with: #{#orderId => orderId, #amount => reservation at: "total"}
      options: #{
        #startToCloseTimeout => 60000,
        #retryPolicy => #{#maximumAttempts => 3}
      }

    // Step 3: Wait for shipping confirmation (signal)
    self.status := "awaiting_shipment"
    shipment := self waitForSignal: "shipment_confirmed" timeout: 86400000

    // Step 4: Send confirmation email (activity)
    self runActivity: OrderActivities >> #sendConfirmationEmail:
      with: #{#orderId => orderId, #tracking => shipment at: "tracking_number"}

    self.status := "completed"
    #{#orderId => orderId, #status => "completed", #tracking => shipment at: "tracking_number"}
```

### 5.2 Defining Activities

Activities are methods on classes that extend `Activity`:

```beamtalk
Activity subclass: OrderActivities

  /// Reserves inventory for an order. May fail if items are out of stock.
  class reserveInventory: args :: Dictionary -> Dictionary =>
    orderId := args at: #orderId
    items := args at: #items
    // Call external inventory service...
    result := HTTPClient post: "https://inventory.example.com/reserve"
      body: (Json generate: #{#orderId => orderId, #items => items})
    (result unwrap) bodyAsJson

  /// Charges a payment method.
  class chargePayment: args :: Dictionary -> Dictionary =>
    // Call payment gateway...
    #{#status => "charged", #transactionId => "txn_abc123"}

  /// Sends a confirmation email.
  class sendConfirmationEmail: args :: Dictionary =>
    // Call email service...
    nil
```

### 5.3 Running Activities from Workflows

Activities are invoked through the Workflow base class API, which dispatches the call to a worker and
records it in the event history:

```beamtalk
// Simple activity call
result := self runActivity: MyActivities >> #doWork:
  with: #{#input => "data"}

// With options
result := self runActivity: MyActivities >> #doWork:
  with: #{#input => "data"}
  options: #{
    #startToCloseTimeout => 30000,
    #retryPolicy => #{
      #initialInterval => 1000,
      #backoffCoefficient => 2.0,
      #maximumAttempts => 5,
      #nonRetryableErrors => #("InvalidInput")
    }
  }
```

During normal execution, `runActivity:with:` dispatches the activity to a worker, waits for the
result, and records `ActivityScheduled` + `ActivityCompleted` events.

During replay, `runActivity:with:` returns the previously recorded result from the event history
without dispatching to a worker.

### 5.4 Signals

Signals are named messages sent to running workflows from external clients or other workflows.
Signals are **buffered by the Engine** and delivered to the Workflow Actor at safe points — between
workflow commands. This is necessary because the Workflow Actor's gen_server process is blocked in a
synchronous call while executing activities, timers, or child workflows, and cannot receive messages
directly.

Signal delivery flow:

1. Client sends signal to the Engine Actor (not the Workflow Actor).
2. Engine records a `SignalReceived` event in the workflow's history.
3. Engine buffers the signal for the target workflow.
4. At the next safe point (when the current blocking command completes), the Workflow base class
   drains buffered signals from the Engine and runs registered signal handlers.
5. Signal handlers execute between commands — never during an activity call.

This matches Temporal's model: signals are reliably recorded and processed in deterministic order,
but are not "instant." What matters is that signals are never lost and replay processes them at the
same history positions.

```beamtalk
Workflow subclass: ApprovalWorkflow
  state: approved :: Boolean = false
  state: approverName :: String

  /// Define signal handlers in the workflow.
  initialize =>
    self onSignal: "approve" do: [:data |
      self.approved := true
      self.approverName := data at: "name"
    ]

  run: requestId :: String -> Dictionary =>
    // Block until signal received or timeout
    self waitForCondition: [self.approved] timeout: 86400000

    self.approved
      ifTrue: [#{#status => "approved", #approver => self.approverName}]
      ifFalse: [#{#status => "timed_out"}]
```

`waitForCondition:timeout:` is a special safe point: it repeatedly drains buffered signals, checks
the condition block, and if the condition is still false, blocks until the Engine notifies it that
new signals have arrived (or the timeout expires).

Sending a signal from a client:

```beamtalk
client := ExduraClient new
client signal: "approval-workflow-123"
  name: "approve"
  payload: #{#name => "Alice"}
```

### 5.5 Queries

Queries read workflow state without modifying it. Queries are handled by the **Engine**, not the
Workflow Actor — because the Workflow Actor may be blocked in a synchronous call and unable to
respond.

The Engine maintains a cached snapshot of each workflow's state, updated at every safe point (after
each command completes). When a query arrives, the Engine evaluates the registered query handler
block against the cached state and returns the result.

Query handlers are registered in the workflow's `initialize` method. Each handler receives a
snapshot proxy as its argument:

```beamtalk
Workflow subclass: OrderWorkflow
  state: status :: String = "pending"

  initialize =>
    self onQuery: "getStatus" do: [:snap | snap.status]
    self onQuery: "getOrder" do: [:snap |
      #{#orderId => snap.orderId, #status => snap.status, #items => snap.items}
    ]
```

Queries see state as of the last completed workflow command. If the workflow is mid-activity, the
query reflects the state before that activity was scheduled.

**Snapshot proxy:** Since queries execute in the Engine (not the blocked Workflow Actor), query
handlers run against a read-only **snapshot proxy** — an `ActorSnapshot` object that captures the
workflow's state via reflection (`fieldNames`, `fieldAt:`) and responds to field-name messages
through `doesNotUnderstand:args:`. This lets query handlers use `snap.status`, `snap.orderId`, etc.
with normal Beamtalk field access syntax, without touching the live Actor process.

```beamtalk
Object subclass: ActorSnapshot
  state: fields :: Dictionary

  /// Capture a read-only snapshot of a live Actor's state fields.
  class of: actor =>
    data := Dictionary new
    actor fieldNames do: [:name |
      data at: name put: (actor fieldAt: name)
    ]
    self new: #{#fields => data}

  /// Respond to any field getter by looking up the captured value.
  doesNotUnderstand: selector args: arguments =>
    self.fields includesKey: selector
      ifTrue: [self.fields at: selector]
      ifFalse: [Error signal: "ActorSnapshot: no field '{selector}'"]
```

At each safe point, the Engine captures a snapshot from the live Workflow Actor. When a query
arrives, the Engine evaluates the registered query handler block, passing the snapshot as an
argument:

```beamtalk
// In Engine, on query:
handler := queryHandlers at: queryName
handler value: snap  // handler block receives snapshot, uses snap.status etc.
```

This exercises Beamtalk's reflection API (`fieldNames`, `fieldAt:`), dynamic dispatch
(`doesNotUnderstand:args:`), and the proxy pattern — all with no language changes.

Querying from a client:

```beamtalk
client := ExduraClient new
status := client query: "order-workflow-456" name: "getStatus"
```

### 5.6 Durable Timers

`Workflow sleep:` creates a durable timer. If the process crashes, replay reconstructs the timer
and fires it at the correct time:

```beamtalk
run: orderId :: String -> Dictionary =>
  // Reserve items
  self runActivity: OrderActivities >> #reserveInventory: with: #{#orderId => orderId}

  // Wait 24 hours for payment
  self sleep: 86400000

  // Check if payment received (query state set by signal handler)
  self.paymentReceived
    ifTrue: [self runActivity: OrderActivities >> #shipOrder: with: #{#orderId => orderId}]
    ifFalse: [self runActivity: OrderActivities >> #cancelReservation: with: #{#orderId => orderId}]
```

### 5.7 Child Workflows

Workflows can start child workflows for decomposition:

```beamtalk
Workflow subclass: BatchProcessor
  run: items :: List -> List =>
    // Fan out to child workflows
    handles := items collect: [:item |
      self startChildWorkflow: ProcessItem >> #run: with: #{#item => item}
    ]

    // Wait for all children to complete
    handles collect: [:h | h result]
```

Parent-close policies:
- `#terminate` — Child is terminated when parent closes (default).
- `#requestCancel` — Cancellation is requested but child may finish.
- `#abandon` — Child continues running independently.

### 5.8 Cancellation

Workflows can be cancelled by clients. Cancellation propagates to pending activities and child
workflows:

```beamtalk
client := ExduraClient new
client cancel: "order-workflow-456"
```

Workflows can handle cancellation for cleanup:

```beamtalk
run: orderId :: String -> Dictionary =>
  reservation := self runActivity: OrderActivities >> #reserveInventory: with: #{#orderId => orderId}
  [
    payment := self runActivity: OrderActivities >> #chargePayment: with: #{#orderId => orderId}
    self runActivity: OrderActivities >> #shipOrder: with: #{#orderId => orderId}
  ] on: CancellationError do: [:e |
    // Compensation — release reservation
    self runActivity: OrderActivities >> #releaseInventory: with: #{#reservation => reservation}
    e signal  // Re-raise cancellation
  ]
```

### 5.9 Saga / Compensation Pattern

For multi-step workflows that need rollback on failure:

```beamtalk
Workflow subclass: TransferWorkflow
  run: from :: String to :: String amount :: Integer -> Dictionary =>
    saga := Saga new

    // Step 1: Debit source account
    debit := self runActivity: AccountActivities >> #debit:
      with: #{#account => from, #amount => amount}
    saga addCompensation: [
      self runActivity: AccountActivities >> #credit: with: #{#account => from, #amount => amount}
    ]

    // Step 2: Credit destination account
    [
      credit := self runActivity: AccountActivities >> #credit:
        with: #{#account => to, #amount => amount}
    ] on: Error do: [:e |
      // Rollback all compensations in reverse order
      saga compensate
      e signal
    ]

    #{#status => "transferred", #debitRef => debit, #creditRef => credit}
```

### 5.10 Continue-As-New

Long-running workflows can reset their event history to prevent unbounded growth:

```beamtalk
Workflow subclass: PollerWorkflow
  run: cursor :: String -> String =>
    // Process a batch
    result := self runActivity: BatchActivities >> #fetchBatch: with: #{#cursor => cursor}
    nextCursor := result at: "nextCursor"

    nextCursor isNil
      ifTrue: ["done"]
      ifFalse: [self continueAsNew: #(nextCursor)]
```

## 6. Deterministic Replay

### 6.1 Replay Invariant

Workflow code must be deterministic: given the same event history, it must produce the same sequence
of commands (activity calls, timer starts, child workflow starts, etc.).

Non-deterministic operations are forbidden in workflow code:
- Direct I/O (file, network, database).
- Random number generation (use `Workflow random` which is seeded from history).
- Current time (use `Workflow now` which returns replay-safe time).
- Spawning unsupervised processes.

All side effects must go through activities.

### 6.2 Replay Mechanics

When a Workflow Actor starts (or restarts after a crash):

1. Load the event history from the Event Store.
2. Create the Workflow Actor with initial state.
3. Re-execute the workflow code from the beginning.
4. For each `runActivity:`, `sleep:`, `startChildWorkflow:`, etc.:
   - Check the event history for a matching recorded result.
   - If found: return the recorded result immediately (no dispatch).
   - If not found: this is a new command — dispatch normally and record the result.
5. Continue until the workflow blocks on a pending command or completes.

### 6.3 State Snapshots

To optimize replay for long-running workflows, the engine periodically records `StateSnapshot`
events containing a serialized copy of the Workflow Actor's state. On replay, the engine can skip
to the most recent snapshot and replay only subsequent events.

Snapshot interval is configurable (default: every 100 events or every 5 minutes).

### 6.4 Versioning

When workflow code changes between deployments, old workflows may need to replay with the new code.
The `Workflow version:` API enables branching:

```beamtalk
run: orderId :: String =>
  v := self version: "payment-flow" defaultVersion: 1 maxVersion: 2
  v == 1
    ifTrue: [self runActivity: PaymentActivities >> #chargeV1: with: #{#orderId => orderId}]
    ifFalse: [self runActivity: PaymentActivities >> #chargeV2: with: #{#orderId => orderId}]
```

### 6.5 Replay Programming Contract

Workflow API methods — `runActivity:with:`, `sleep:`, `startChildWorkflow:`, `waitForSignal:`,
`waitForCondition:timeout:` — are **synchronous blocking calls** on the Workflow Actor process. No
coroutines, continuations, or compiler transforms are involved.

During **normal (non-replay) execution:**

1. The method sends a command message to the Workflow Engine (e.g., "schedule activity X").
2. The Engine records the command as an event (`ActivityScheduled`).
3. The Workflow Actor process blocks, waiting for a result message.
4. When the activity completes, the Engine records the result (`ActivityCompleted`) and sends the
   result back to the Workflow Actor.
5. The blocking method returns the result, and workflow code continues.

During **replay execution** (after a crash or restart):

1. The method checks the event history at the current replay cursor position.
2. If a matching result event exists (e.g., `ActivityCompleted` for this activity call), the method
   returns the recorded result immediately — no message is sent, no blocking occurs.
3. If no matching event exists, this is a **new command** — execution switches to normal mode and
   the activity is dispatched as above.

This model works because:

- Beamtalk Actors are BEAM processes. BEAM processes are cheap and can block indefinitely without
  affecting other processes.
- The workflow code is sequential — each `runActivity:with:` call naturally suspends the workflow
  until the result arrives, whether from a real activity execution or from the event history.
- No special language support is needed. The Workflow base class methods handle the replay logic
  internally. Workflow authors write ordinary sequential Beamtalk code against the `self` API.

**Determinism contract:** Workflow code must only perform side effects through `self` methods on the
Workflow base class. Direct I/O, random number generation, or time queries outside of `self now` and
`self random` will produce different results on replay and corrupt the workflow.

**Safe points and signal delivery:** Workflow commands (`runActivity:with:`, `sleep:`,
`startChildWorkflow:`, `waitForSignal:`, `waitForCondition:timeout:`) are **safe points**. Between
safe points, workflow code runs atomically — no signals are delivered, no queries are served. At each
safe point, after the blocking call returns:

1. The Workflow base class drains any buffered signals from the Engine.
2. Registered signal handlers execute against the current workflow state.
3. Signal handling events are recorded in the history (for deterministic replay).
4. The Engine's cached state snapshot is updated (for query serving).
5. Workflow code continues to the next command.

This model keeps signal delivery deterministic: during replay, signals appear at the same history
positions as in the original execution. The Workflow Actor's gen_server is never interrupted
mid-command.

**Why signals go through the Engine:** The Workflow Actor process is blocked in a synchronous
gen_server:call while waiting for activity results. BEAM gen_servers process one message at a time —
while blocked, the Actor cannot receive signals or queries. Routing signals and queries through the
Engine (which is always responsive) avoids this limitation. This is the same approach Temporal uses:
signals queue up and are delivered between workflow tasks.

**Durable timer reconstruction:** `self sleep: duration` records a `TimerStarted` event. On replay,
if `TimerFired` is already in the history, `sleep:` returns immediately. If `TimerStarted` exists
but `TimerFired` does not, the engine calculates the remaining wall-clock duration and arms a new
`erlang:send_after` for the remainder (or fires immediately if the original fire time has passed).
The stdlib `Timer` class is not used — durable timers are a Workflow Engine primitive.

## 7. Client API

### 7.1 Workflow Operations

```beamtalk
client := ExduraClient connect: #{#host => "localhost", #port => 4100}

// Start a workflow
handle := client start: OrderWorkflow
  id: "order-123"
  args: #("order-123", #(#{#sku => "ABC", #qty => 2}))
  taskQueue: "orders"
  options: #{
    #workflowExecutionTimeout => 86400000,
    #retryPolicy => #{#maximumAttempts => 3}
  }

// Wait for result
result := handle result  // Blocks until workflow completes

// Get result with timeout
result := handle result: 30000  // Timeout in ms

// Signal a running workflow
client signal: "order-123" name: "shipment_confirmed"
  payload: #{#tracking_number => "1Z999AA10123456784"}

// Query workflow state
status := client query: "order-123" name: "getStatus"

// Cancel a workflow
client cancel: "order-123"

// List workflows
workflows := client list: #{
  #status => "running",
  #workflowType => "OrderWorkflow",
  #startedAfter => "2026-01-01T00:00:00Z"
}
```

### 7.2 HTTP API (Optional)

For non-Beamtalk clients, Exdura exposes an optional REST/JSON API:

```
POST   /api/v1/workflows                    — Start a workflow
GET    /api/v1/workflows/:id                — Get workflow status
POST   /api/v1/workflows/:id/signal/:name   — Send a signal
GET    /api/v1/workflows/:id/query/:name    — Execute a query
POST   /api/v1/workflows/:id/cancel         — Cancel a workflow
GET    /api/v1/workflows                    — List/search workflows
GET    /api/v1/workflows/:id/history        — Get event history
```

## 8. Worker Configuration

Workers are configured and started as part of the application's supervision tree:

```beamtalk
// In application supervisor
ExduraWorker start: #{
  #taskQueue => "orders",
  #workflows => #(OrderWorkflow, ApprovalWorkflow, BatchProcessor),
  #activities => #(OrderActivities, PaymentActivities, EmailActivities),
  #maxConcurrentWorkflows => 100,
  #maxConcurrentActivities => 50
}
```

### 8.1 Worker Supervision

Each worker runs under an OTP supervisor:

```
ExduraSupervisor (one_for_one)
├── WorkflowEngine (Actor)
├── EventStore (Actor — wraps ETS+file/Khepri/etc.)
├── WorkflowWorkerPool (pool_supervisor)
│   ├── WorkflowWorker-1
│   ├── WorkflowWorker-2
│   └── ...
├── ActivityWorkerPool (pool_supervisor)
│   ├── ActivityWorker-1
│   ├── ActivityWorker-2
│   └── ...
├── TimerManager (Actor)
├── HttpServer (optional)
└── Scheduler (optional)
```

### 8.2 Task Queue Routing

- Workflows and activities are assigned to named task queues.
- Workers register for specific task queues.
- Multiple workers can serve the same queue (load balancing).
- Different queues can have different worker pools with different concurrency limits.

## 9. Persistence

### 9.1 Event Store Interface

The Event Store is a pluggable interface with these operations:

```beamtalk
// Append events to a workflow's history
appendEvents: workflowId :: String events: events :: List -> Result

// Read all events for a workflow (from optional sequence number)
readEvents: workflowId :: String from: fromSeq :: Integer -> Result

// Read events from the latest snapshot
readEventsFromSnapshot: workflowId :: String -> Result

// Save a state snapshot
saveSnapshot: workflowId :: String state: state :: Dictionary eventId: eventId :: Integer -> Result

// Get workflow execution metadata
getExecution: workflowId :: String -> Result

// Update workflow execution status
updateExecution: workflowId :: String status: status :: Symbol result: result -> Result

// List/search workflow executions
listExecutions: filter :: Dictionary -> Result
```

### 9.2 ETS + File Backend (v1 Default)

v1 ships with a minimal, single-node Event Store:

- **ETS tables** (in-memory, via Beamtalk's `Ets` class):
  - `exdura_executions` — Workflow execution metadata, keyed by `workflow_id`.
  - `exdura_timers` — Pending durable timers.
- **Append-only files** (on-disk, via Beamtalk's `File` class):
  - One file per workflow: `data/events/{workflow_id}.etf` — ETF-encoded event history.
  - Snapshot file: `data/snapshots/{workflow_id}.etf` — latest state snapshot.

This backend is simple and exercises Beamtalk's `Ets` and `File` stdlib classes directly. It
provides durability for single-node restarts with no external dependencies.

Limitations: no concurrent writer safety (single-node only), no built-in indexing for visibility
queries (linear scan), no replication.

### 9.3 Khepri Backend (Future — Multi-Node)

For multi-node BEAM clusters, Khepri provides Raft-based consensus and replication — solving the
split-brain problems that make Mnesia unsuitable for distributed workflows. Khepri's tree-structured
data model maps naturally to workflow event histories keyed by path
(`/workflows/{id}/events/{seq}`).

### 9.4 PostgreSQL Backend (Future — Production)

For production deployments with stronger durability and operational tooling:
- Standard schema with `workflow_executions`, `workflow_events`, `workflow_snapshots` tables.
- Connection pooling via a supervised pool Actor.
- Indexed `workflow_type`, `status`, `started_at`, and custom search attributes for visibility
  queries.

## 10. Observability

### 10.1 Structured Logging

All workflow and activity lifecycle events emit structured log entries:
- Workflow started/completed/failed/cancelled.
- Activity scheduled/started/completed/failed (with duration).
- Signal received.
- Timer started/fired.
- Replay started/completed (with event count and duration).

### 10.2 Metrics

Key metrics to expose:
- `exdura_workflow_started_total` (counter, by workflow_type).
- `exdura_workflow_completed_total` (counter, by workflow_type, status).
- `exdura_workflow_duration_seconds` (histogram, by workflow_type).
- `exdura_activity_scheduled_total` (counter, by activity_type).
- `exdura_activity_duration_seconds` (histogram, by activity_type).
- `exdura_task_queue_depth` (gauge, by task_queue).
- `exdura_replay_duration_seconds` (histogram).
- `exdura_replay_events_total` (counter).

### 10.3 Workflow History

Every workflow's complete event history is queryable through the client API. This provides a
detailed audit trail of every step, decision, and side effect.

## 11. Error Handling

### 11.1 Activity Errors

Activity failures are retried according to the RetryPolicy. After exhausting retries, the error
propagates to the workflow as an `ActivityError`.

Workflows handle activity errors using standard Beamtalk error handling:

```beamtalk
result := [
  self runActivity: MyActivities >> #riskyOperation: with: #{#data => data}
] on: ActivityError do: [:e |
  // Handle failure — maybe run compensation or use fallback
  self runActivity: MyActivities >> #fallbackOperation: with: #{#data => data}
]
```

### 11.2 Workflow Errors

Unhandled errors in workflow code cause the workflow to fail. The error is recorded in the event
history and the workflow's status becomes `failed`.

### 11.3 Non-Retryable Errors

Activities can throw non-retryable errors to skip the retry policy:

```beamtalk
class validateInput: args :: Dictionary =>
  input := args at: #input
  input isNil ifTrue: [
    NonRetryableError signal: "Input is required"
  ]
```

## 12. Testing

### 12.1 Workflow Testing

Exdura provides a test environment that executes workflows synchronously without persistence:

```beamtalk
TestCase subclass: OrderWorkflowTest

  testHappyPath =>
    env := ExduraTestEnv new
    env mockActivity: OrderActivities >> #reserveInventory:
      returning: #{#total => 99.99, #reservationId => "res-1"}
    env mockActivity: OrderActivities >> #chargePayment:
      returning: #{#status => "charged", #transactionId => "txn-1"}
    env mockActivity: OrderActivities >> #sendConfirmationEmail:
      returning: nil

    // Arrange signal to fire when workflow waits for it
    env onSignalWait: "shipment_confirmed"
      deliver: #{#tracking_number => "1Z999"}

    result := env run: OrderWorkflow with: #("order-1", #(#{#sku => "ABC", #qty => 2}))
    self assert: (result at: "status") equals: "completed"
    self assert: (result at: "tracking") equals: "1Z999"

  testPaymentFailure =>
    env := ExduraTestEnv new
    env mockActivity: OrderActivities >> #reserveInventory:
      returning: #{#total => 99.99}
    env mockActivity: OrderActivities >> #chargePayment:
      raising: (ActivityError new: "card_declined")

    result := [env run: OrderWorkflow with: #("order-1", #())]
      on: WorkflowError do: [:e | e]
    self assert: result message includesSubstring: "card_declined"
```

### 12.2 Activity Testing

Activities are plain class methods and can be tested directly:

```beamtalk
TestCase subclass: OrderActivitiesTest

  testReserveInventory =>
    result := OrderActivities reserveInventory: #{
      #orderId => "test-1",
      #items => #(#{#sku => "ABC", #qty => 1})
    }
    self assert: (result at: "total") > 0
```

## 13. What Exdura Does Differently

Exdura is inspired by Temporal's programming model but is not a Temporal clone. Key differences
arise from building natively on the BEAM:

### 13.1 Supervision Instead of External Orchestration

Temporal requires a separate server cluster (Go binary) running alongside your application. Exdura
is an OTP application — the workflow engine, workers, and event store are supervised Actors in your
application's own supervision tree. No external process to operate.

```beamtalk
// Your application IS the workflow engine
Supervisor subclass: MyApp
  class strategy => #oneForOne
  class children => #(ExduraSupervisor, MyHttpServer, MyMetrics)
```

### 13.2 Actor State Is Workflow State

In Temporal, workflow state is reconstructed entirely from the event history — the workflow function
is stateless between tasks. In Exdura, the Workflow Actor's `state:` fields are live, mutable state
that persists across activity calls (the Actor process stays alive). Event sourcing provides crash
recovery, not primary state management.

This means workflows can use normal Actor patterns — accumulating state, responding to queries via
cached fields — without constantly reconstructing from history.

### 13.3 BEAM-Native Error Handling

Temporal uses language-specific error wrapping (Go `error`, Java exceptions). Exdura uses
Beamtalk's `on:do:` blocks, which compile to Erlang's `try/catch` — the same error handling that
OTP supervisors, gen_servers, and the entire BEAM ecosystem uses. No wrapper types, no special
error SDK.

### 13.4 Hot Activity Reload

Activity classes can be hot-reloaded while the system is running — a BEAM-native capability that
Temporal cannot offer. New activity code takes effect immediately for newly scheduled activities
without restarting workers or draining task queues. (Workflow classes use versioning instead — see
§6.4.)

## 14. Beamtalk Language Features Exercised

This project exercises Beamtalk features that Symphony did not stress:

| Feature | How Exdura exercises it |
|---|---|
| Deep inheritance | Workflow, Activity, EventStore base classes with user subclasses |
| Actor pools | Activity worker pools (many instances of same class) |
| Complex error handling | Saga compensation, `on:do:` chains, non-retryable errors |
| Serialization | Event history persistence (ETF), state snapshots |
| Method chaining | Client API fluent interface, query/filter builders |
| Heavy `on:do:` blocks | Compensation logic, cancellation handlers, retry interceptors |
| `>>` method references | Activity dispatch via `Class >> #selector:` (CompiledMethod lookup) |
| DNU proxy pattern | `ActorSnapshot` uses `doesNotUnderstand:args:` + `fieldAt:` for read-only Actor state proxies |
| Reflection API | `fieldNames`, `fieldAt:` for snapshot capture; `perform:withArguments:` for dynamic dispatch |
| Dynamic dispatch | Activity routing by type name, signal handler lookup |
| Large state maps | Workflow state accumulated over many events |
| Hot code reload | Activity classes only — workflow classes must use versioning (§6.4) to avoid breaking the replay invariant. Hot-reloading workflow code while executions are in-flight produces different commands on replay and corrupts workflows. |
| Multi-node distribution | Future goal — v1 is single-node. Will exercise once Beamtalk clustering is proven. |
| OTP supervision depth | Per-workflow supervisors under pool supervisors under engine |

## 15. Implementation Phases

### Phase 0: Proof of Mechanism

Prove the core replay mechanism works before building the full API surface.

- Workflow Actor base class with `run:` and `runActivity:with:`.
- Single Activity class with one class method.
- In-memory event store (ETS only, no file persistence).
- Execute a workflow that calls one activity, crash the Workflow Actor, restart it, verify replay
  produces the same result without re-executing the activity.
- No client API, no task queue — direct Actor message sends.

Success criterion: a test that demonstrates correct replay after crash.

### Phase 1: Core Engine (MVP)

- Full `Workflow` base class: `runActivity:with:options:`, `sleep:`.
- `Activity` base class and supervised activity worker pool (DynamicSupervisor).
- ETS + append-only file event store (§9.2).
- Deterministic replay from persisted event history (survives node restart).
- Client API: start, wait for result.
- Single task queue, single worker.

### Phase 2: Signals, Queries, and Timers

- Signal and query handler registration.
- `waitForSignal:`, `waitForCondition:timeout:`.
- Durable timers with reconstruction on replay (§6.5).
- State snapshots for replay optimization.

### Phase 3: Advanced Patterns

- Child workflows with parent-close policies.
- Saga helper class.
- Cancellation propagation.
- Continue-as-new.
- Workflow versioning (§6.4).
- Activity heartbeating.

### Phase 4: Production Readiness

- Khepri or PostgreSQL event store backend.
- HTTP API for non-Beamtalk clients.
- Visibility store and workflow search.
- Cron scheduler.
- Metrics export.
- Multi-node task queue routing (requires Beamtalk clustering support).

## 16. Resolved Design Questions

1. **Replay determinism enforcement**: Rely on documentation and testing for v1. Compiler-level
   enforcement would require a purity/effect system that Beamtalk doesn't have. Temporal takes the
   same approach. A lint rule can be added later if non-determinism bugs become a recurring problem.

2. **Event serialization format**: ETF internally, JSON at HTTP API boundary (§3.5).

3. **Workflow identity**: Caller-assigned with auto-generated fallback. `client start: Workflow
   id: "order-123"` uses the caller's ID. Omit `id:` and the engine generates a UUID.

4. **Task queue implementation**: Dedicated queue Actor wrapping an ETS-backed queue. Process
   mailboxes are FIFO with no visibility — no depth inspection, no backpressure, no prioritization.
   A queue Actor provides `depth`, `peek`, and a natural extension point for backpressure. Also
   exercises more Beamtalk features (Actor + ETS composition).

5. **Multi-tenancy**: Deferred. v1 does not support namespace isolation — use separate deployments.
   This is a language exercise, not a multi-tenant SaaS platform.

6. **Workflow size limits**: 50,000 events per workflow execution, matching Temporal's default. The
   engine logs a warning at 40,000 events (80%) and returns an error at the limit, requiring
   `continueAsNew:` to reset the history.
