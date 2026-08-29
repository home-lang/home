#pragma once

namespace WebCore {
class ScriptExecutionContext;
class Worker;

namespace WorkerSnapshots {
// Called on the parent's context thread before its Worker exit event.
void cancelForWorker(Worker&, ScriptExecutionContext&);
}
}
