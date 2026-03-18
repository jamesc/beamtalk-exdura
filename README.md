# Exdura

A Temporal-inspired durable workflow engine built in [Beamtalk](https://beamtalk.dev) on the BEAM.

Workflows are ordinary sequential code. The engine handles persistence, retries, and failure recovery transparently through event-sourced replay.

## Example

Define a workflow and its activities:

```beamtalk
/// Activities are stateless — class methods that do real work.
Activity subclass: OrderActivities

  class reserveInventory: args =>
    // Call external inventory service...
    #{#status => "reserved", #itemId => (args at: #itemId)}

  class chargePayment: args =>
    // Call payment gateway...
    #{#status => "charged", #amount => (args at: #amount)}
```

```beamtalk
/// Workflows are sequential code. The engine makes them durable.
Workflow subclass: OrderWorkflow

  run: order ctx: ctx =>
    // Each activity is recorded — on crash, replay skips completed steps
    inventory := ctx
      runActivity: OrderActivities
      method: #reserveInventory:
      with: #(order)

    payment := ctx
      runActivity: OrderActivities
      method: #chargePayment:
      with: #(order)

    #{#inventory => inventory, #payment => payment}
```

Start the engine and run a workflow:

```beamtalk
// Boot the supervision tree
client := ExduraClient connect: #{}

// Start a workflow
handle := client
  start: OrderWorkflow
  id: "order-123"
  args: #(#{#itemId => "SKU-42", #amount => 2999})
  taskQueue: "default"
  options: #{}

// Block until the workflow completes
result := handle result
// => #{#inventory => #{#status => "reserved", ...},
//     #payment => #{#status => "charged", ...}}
```

The full event history is persisted automatically:

```
1: WorkflowStarted   — OrderWorkflow with args
2: ActivityScheduled  — OrderActivities.reserveInventory:
3: ActivityCompleted  — #{#status => "reserved", ...}
4: ActivityScheduled  — OrderActivities.chargePayment:
5: ActivityCompleted  — #{#status => "charged", ...}
6: WorkflowCompleted  — final result
```

If the process crashes after step 3, the engine replays events 1-3 (skipping the completed activity) and resumes live execution from step 4.

## Features

- **Durable execution** — workflows survive crashes via event-sourced replay
- **Activity retry** — exponential backoff with configurable retry policies
- **Supervised worker pool** — activities run in isolated, supervised processes
- **Signals** — send data to running workflows with buffered delivery at safe points
- **Queries** — read workflow state without affecting execution
- **Timers** — durable sleep that reconstructs remaining time on replay
- **Child workflows** — fan-out/fan-in patterns with parent-close policies
- **Sagas** — compensation-based rollback for distributed transactions
- **Continue-as-new** — reset event history for long-running workflows
- **Versioning** — safe code changes for in-flight workflows
- **Cancellation** — propagates through child workflows with cleanup hooks
- **State snapshots** — replay optimization for long event histories
- **File persistence** — append-only ETF event logs survive node restarts

## Try it in the REPL

```bash
beamtalk repl
```

```beamtalk
// Load the example workflows (src/ is auto-loaded)
:load "examples/"

// Boot the engine and run a workflow
client := ExduraClient connect: #{}

handle := client
  start: DoubleWorkflow
  id: "demo-1"
  args: #(5)
  taskQueue: "default"
  options: #{}

result := handle result: 5000
// => 20  (5 doubled to 10, then 10+10=20)

// Inspect the event history
history := client eventStore readEvents: "demo-1" fromSeq: 1
history do: [:e | Transcript show: "{e eventId}: {e eventType}"; cr]
// 1: WorkflowStarted
// 2: ActivityScheduled
// 3: ActivityCompleted
// 4: ActivityScheduled
// 5: ActivityCompleted
// 6: WorkflowCompleted
```

## Building

```bash
beamtalk build
```

## Testing

```bash
beamtalk test
```

## Project Structure

```
src/              Library source — engine, actors, data model
test/             BUnit test suites
test/fixtures/    Test-only workflows and activities
SPEC.md           Full specification
AGENTS.md         Agent development guide
```

## Spec

See [SPEC.md](SPEC.md) for the full specification covering all four phases:

- **Phase 0**: Proof of mechanism (event model, replay)
- **Phase 1**: Core engine MVP (retry, pools, persistence, client API)
- **Phase 2**: Signals, queries, timers, snapshots
- **Phase 3**: Child workflows, sagas, cancellation, versioning
