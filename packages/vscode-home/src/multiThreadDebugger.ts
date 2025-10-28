import {
    DebugProtocol
} from 'vscode-debugprotocol';

/**
 * Multi-Threaded Debugger
 *
 * Handles debugging of multi-threaded Home programs.
 * Tracks thread state, synchronization, deadlocks, and race conditions.
 */

export interface ThreadInfo {
    id: number;
    name: string;
    state: ThreadState;
    stackFrames: StackFrame[];
    currentLine: number;
    currentFile: string;
}

export enum ThreadState {
    Running = 'running',
    Stopped = 'stopped',
    Waiting = 'waiting',
    Blocked = 'blocked',
    Terminated = 'terminated'
}

export interface StackFrame {
    id: number;
    name: string;
    file: string;
    line: number;
    column: number;
}

export interface SynchronizationEvent {
    timestamp: number;
    type: 'lock' | 'unlock' | 'wait' | 'notify' | 'join';
    threadId: number;
    resourceId: string;
    stackTrace: string[];
}

export interface DeadlockInfo {
    detectedAt: number;
    threads: number[];
    resources: string[];
    description: string;
    cycle: DeadlockCycle[];
}

export interface DeadlockCycle {
    threadId: number;
    holdsResource: string;
    waitsForResource: string;
    blockedByThread: number;
}

export interface RaceCondition {
    timestamp: number;
    variable: string;
    thread1: {
        id: number;
        operation: 'read' | 'write';
        stackTrace: string[];
    };
    thread2: {
        id: number;
        operation: 'read' | 'write';
        stackTrace: string[];
    };
}

export class MultiThreadDebugger {
    private threads: Map<number, ThreadInfo> = new Map();
    private syncEvents: SynchronizationEvent[] = [];
    private resourceOwners: Map<string, number> = new Map(); // resource -> thread ID
    private threadWaiting: Map<number, string> = new Map(); // thread -> resource
    private detectedDeadlocks: DeadlockInfo[] = [];
    private detectedRaces: RaceCondition[] = [];

    /**
     * Register a new thread
     */
    public registerThread(
        id: number,
        name: string,
        state: ThreadState = ThreadState.Running
    ): void {
        this.threads.set(id, {
            id,
            name,
            state,
            stackFrames: [],
            currentLine: 0,
            currentFile: ''
        });
    }

    /**
     * Update thread state
     */
    public updateThreadState(id: number, state: ThreadState): void {
        const thread = this.threads.get(id);
        if (thread) {
            thread.state = state;
        }
    }

    /**
     * Update thread stack frames
     */
    public updateThreadStack(id: number, stackFrames: StackFrame[]): void {
        const thread = this.threads.get(id);
        if (thread) {
            thread.stackFrames = stackFrames;
            if (stackFrames.length > 0) {
                thread.currentFile = stackFrames[0].file;
                thread.currentLine = stackFrames[0].line;
            }
        }
    }

    /**
     * Get all threads
     */
    public getAllThreads(): ThreadInfo[] {
        return Array.from(this.threads.values());
    }

    /**
     * Get active threads
     */
    public getActiveThreads(): ThreadInfo[] {
        return Array.from(this.threads.values()).filter(
            t => t.state === ThreadState.Running || t.state === ThreadState.Stopped
        );
    }

    /**
     * Record synchronization event
     */
    public recordSyncEvent(
        type: 'lock' | 'unlock' | 'wait' | 'notify' | 'join',
        threadId: number,
        resourceId: string,
        stackTrace: string[]
    ): void {
        const event: SynchronizationEvent = {
            timestamp: Date.now(),
            type,
            threadId,
            resourceId,
            stackTrace
        };

        this.syncEvents.push(event);

        // Update resource ownership
        if (type === 'lock') {
            this.resourceOwners.set(resourceId, threadId);
            this.threadWaiting.delete(threadId);
        } else if (type === 'unlock') {
            this.resourceOwners.delete(resourceId);
        } else if (type === 'wait') {
            this.threadWaiting.set(threadId, resourceId);
            this.updateThreadState(threadId, ThreadState.Waiting);
        }

        // Check for deadlocks after lock/wait events
        if (type === 'lock' || type === 'wait') {
            this.detectDeadlocks();
        }
    }

    /**
     * Detect deadlocks
     */
    private detectDeadlocks(): void {
        const graph = this.buildWaitGraph();
        const cycles = this.findCycles(graph);

        for (const cycle of cycles) {
            if (cycle.length > 1) {
                const deadlock = this.analyzeDeadlock(cycle);
                if (deadlock) {
                    this.detectedDeadlocks.push(deadlock);
                }
            }
        }
    }

    /**
     * Build wait-for graph
     */
    private buildWaitGraph(): Map<number, number[]> {
        const graph = new Map<number, number[]>();

        // For each waiting thread
        for (const [threadId, resourceId] of this.threadWaiting) {
            const ownerThreadId = this.resourceOwners.get(resourceId);
            if (ownerThreadId !== undefined) {
                if (!graph.has(threadId)) {
                    graph.set(threadId, []);
                }
                graph.get(threadId)!.push(ownerThreadId);
            }
        }

        return graph;
    }

    /**
     * Find cycles in wait-for graph (simplified DFS)
     */
    private findCycles(graph: Map<number, number[]>): number[][] {
        const cycles: number[][] = [];
        const visited = new Set<number>();
        const recursionStack = new Set<number>();

        const dfs = (node: number, path: number[]): void => {
            visited.add(node);
            recursionStack.add(node);
            path.push(node);

            const neighbors = graph.get(node) || [];
            for (const neighbor of neighbors) {
                if (!visited.has(neighbor)) {
                    dfs(neighbor, [...path]);
                } else if (recursionStack.has(neighbor)) {
                    // Found a cycle
                    const cycleStart = path.indexOf(neighbor);
                    if (cycleStart !== -1) {
                        cycles.push(path.slice(cycleStart));
                    }
                }
            }

            recursionStack.delete(node);
        };

        for (const node of graph.keys()) {
            if (!visited.has(node)) {
                dfs(node, []);
            }
        }

        return cycles;
    }

    /**
     * Analyze deadlock cycle
     */
    private analyzeDeadlock(cycle: number[]): DeadlockInfo | null {
        const deadlockCycle: DeadlockCycle[] = [];

        for (let i = 0; i < cycle.length; i++) {
            const threadId = cycle[i];
            const nextThreadId = cycle[(i + 1) % cycle.length];

            const waitingFor = this.threadWaiting.get(threadId);
            if (!waitingFor) continue;

            const holdsResource = Array.from(this.resourceOwners.entries())
                .find(([_, owner]) => owner === threadId)?.[0];

            if (holdsResource) {
                deadlockCycle.push({
                    threadId,
                    holdsResource,
                    waitsForResource: waitingFor,
                    blockedByThread: nextThreadId
                });
            }
        }

        if (deadlockCycle.length === 0) return null;

        return {
            detectedAt: Date.now(),
            threads: cycle,
            resources: deadlockCycle.map(c => c.holdsResource),
            description: this.generateDeadlockDescription(deadlockCycle),
            cycle: deadlockCycle
        };
    }

    /**
     * Generate human-readable deadlock description
     */
    private generateDeadlockDescription(cycle: DeadlockCycle[]): string {
        const parts = cycle.map(
            c =>
                `Thread ${c.threadId} holds ${c.holdsResource} and waits for ${c.waitsForResource}`
        );
        return parts.join(', ');
    }

    /**
     * Get detected deadlocks
     */
    public getDeadlocks(): DeadlockInfo[] {
        return this.detectedDeadlocks;
    }

    /**
     * Detect race conditions
     */
    public detectRaceCondition(
        variable: string,
        threadId: number,
        operation: 'read' | 'write',
        stackTrace: string[]
    ): void {
        // Simple race detection: conflicting accesses to same variable
        // In real implementation, would track happens-before relationships

        const recentAccess = this.findRecentAccessToVariable(variable, threadId);
        if (
            recentAccess &&
            (operation === 'write' || recentAccess.operation === 'write')
        ) {
            const race: RaceCondition = {
                timestamp: Date.now(),
                variable,
                thread1: {
                    id: recentAccess.threadId,
                    operation: recentAccess.operation,
                    stackTrace: recentAccess.stackTrace
                },
                thread2: {
                    id: threadId,
                    operation,
                    stackTrace
                }
            };

            this.detectedRaces.push(race);
        }
    }

    /**
     * Find recent access to variable by different thread
     */
    private findRecentAccessToVariable(
        variable: string,
        excludeThreadId: number
    ): { threadId: number; operation: 'read' | 'write'; stackTrace: string[] } | null {
        // In real implementation, would maintain access history
        return null;
    }

    /**
     * Get detected race conditions
     */
    public getRaceConditions(): RaceCondition[] {
        return this.detectedRaces;
    }

    /**
     * Get synchronization timeline
     */
    public getSyncTimeline(): SynchronizationEvent[] {
        return this.syncEvents.sort((a, b) => a.timestamp - b.timestamp);
    }

    /**
     * Get thread-specific synchronization events
     */
    public getThreadSyncEvents(threadId: number): SynchronizationEvent[] {
        return this.syncEvents.filter(e => e.threadId === threadId);
    }

    /**
     * Get resource contention statistics
     */
    public getResourceContention(): Map<string, ResourceContentionStats> {
        const stats = new Map<string, ResourceContentionStats>();

        for (const event of this.syncEvents) {
            if (!stats.has(event.resourceId)) {
                stats.set(event.resourceId, {
                    resourceId: event.resourceId,
                    lockAttempts: 0,
                    lockAcquired: 0,
                    contentionEvents: 0,
                    averageWaitTime: 0,
                    maxWaitTime: 0
                });
            }

            const stat = stats.get(event.resourceId)!;

            if (event.type === 'lock') {
                stat.lockAttempts++;
                stat.lockAcquired++;
            } else if (event.type === 'wait') {
                stat.contentionEvents++;
            }
        }

        return stats;
    }

    /**
     * Clear all tracking data
     */
    public clear(): void {
        this.threads.clear();
        this.syncEvents = [];
        this.resourceOwners.clear();
        this.threadWaiting.clear();
        this.detectedDeadlocks = [];
        this.detectedRaces = [];
    }
}

export interface ResourceContentionStats {
    resourceId: string;
    lockAttempts: number;
    lockAcquired: number;
    contentionEvents: number;
    averageWaitTime: number;
    maxWaitTime: number;
}
