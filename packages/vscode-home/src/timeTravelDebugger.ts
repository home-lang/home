import {
    DebugProtocol
} from 'vscode-debugprotocol';

/**
 * Time-Travel Debugging
 *
 * Records execution history and allows stepping backwards through program execution.
 * Captures snapshots of program state at each step for reverse execution.
 */

export interface ExecutionSnapshot {
    timestamp: number;
    sequenceNumber: number;
    threadId: number;
    stackFrames: StackFrameSnapshot[];
    variables: VariableSnapshot[];
    heap: HeapSnapshot;
    registers: RegisterSnapshot;
    instruction: InstructionSnapshot;
}

export interface StackFrameSnapshot {
    id: number;
    name: string;
    source: string;
    line: number;
    column: number;
    scopes: ScopeSnapshot[];
}

export interface ScopeSnapshot {
    name: string;
    variablesReference: number;
    expensive: boolean;
}

export interface VariableSnapshot {
    name: string;
    value: string;
    type: string;
    variablesReference: number;
    memoryAddress?: string;
}

export interface HeapSnapshot {
    allocations: AllocationSnapshot[];
    totalSize: number;
    freeSize: number;
}

export interface AllocationSnapshot {
    address: string;
    size: number;
    type: string;
    referencedBy: string[];
}

export interface RegisterSnapshot {
    pc: number;  // Program counter
    sp: number;  // Stack pointer
    bp: number;  // Base pointer
    flags: number;
}

export interface InstructionSnapshot {
    address: number;
    opcode: string;
    operands: string[];
    assemblyLine: string;
}

export class TimeTravelDebugger {
    private snapshots: ExecutionSnapshot[] = [];
    private currentSnapshotIndex: number = -1;
    private maxSnapshots: number = 10000; // Configurable limit
    private recordingEnabled: boolean = true;

    /**
     * Record a snapshot of current execution state
     */
    public recordSnapshot(snapshot: ExecutionSnapshot): void {
        if (!this.recordingEnabled) {
            return;
        }

        // Trim snapshots if we're in the middle of history and moving forward
        if (this.currentSnapshotIndex < this.snapshots.length - 1) {
            this.snapshots = this.snapshots.slice(0, this.currentSnapshotIndex + 1);
        }

        // Add new snapshot
        this.snapshots.push(snapshot);
        this.currentSnapshotIndex = this.snapshots.length - 1;

        // Enforce max snapshots limit (FIFO)
        if (this.snapshots.length > this.maxSnapshots) {
            this.snapshots.shift();
            this.currentSnapshotIndex--;
        }
    }

    /**
     * Step backwards in execution history
     */
    public stepBack(): ExecutionSnapshot | null {
        if (this.currentSnapshotIndex <= 0) {
            return null; // Already at beginning
        }

        this.currentSnapshotIndex--;
        return this.snapshots[this.currentSnapshotIndex];
    }

    /**
     * Step forward in execution history (after stepping back)
     */
    public stepForward(): ExecutionSnapshot | null {
        if (this.currentSnapshotIndex >= this.snapshots.length - 1) {
            return null; // Already at end
        }

        this.currentSnapshotIndex++;
        return this.snapshots[this.currentSnapshotIndex];
    }

    /**
     * Continue backwards until breakpoint or beginning
     */
    public reverseExecute(): ExecutionSnapshot | null {
        // Find previous breakpoint or go to beginning
        for (let i = this.currentSnapshotIndex - 1; i >= 0; i--) {
            // Check if this snapshot is at a breakpoint
            // In real implementation, check against breakpoint list
            if (this.isAtBreakpoint(this.snapshots[i])) {
                this.currentSnapshotIndex = i;
                return this.snapshots[i];
            }
        }

        // No breakpoint found, go to beginning
        if (this.snapshots.length > 0) {
            this.currentSnapshotIndex = 0;
            return this.snapshots[0];
        }

        return null;
    }

    /**
     * Get current snapshot
     */
    public getCurrentSnapshot(): ExecutionSnapshot | null {
        if (this.currentSnapshotIndex < 0 || this.currentSnapshotIndex >= this.snapshots.length) {
            return null;
        }
        return this.snapshots[this.currentSnapshotIndex];
    }

    /**
     * Get snapshot at specific sequence number
     */
    public getSnapshotBySequence(sequenceNumber: number): ExecutionSnapshot | null {
        return this.snapshots.find(s => s.sequenceNumber === sequenceNumber) || null;
    }

    /**
     * Get all snapshots between two points
     */
    public getSnapshotRange(startSeq: number, endSeq: number): ExecutionSnapshot[] {
        return this.snapshots.filter(
            s => s.sequenceNumber >= startSeq && s.sequenceNumber <= endSeq
        );
    }

    /**
     * Compare two snapshots to see what changed
     */
    public compareSnapshots(
        snapshot1: ExecutionSnapshot,
        snapshot2: ExecutionSnapshot
    ): SnapshotDiff {
        const diff: SnapshotDiff = {
            variableChanges: [],
            heapChanges: [],
            stackChanges: [],
            registerChanges: []
        };

        // Compare variables
        snapshot2.variables.forEach(v2 => {
            const v1 = snapshot1.variables.find(v => v.name === v2.name);
            if (!v1 || v1.value !== v2.value) {
                diff.variableChanges.push({
                    name: v2.name,
                    oldValue: v1?.value || 'undefined',
                    newValue: v2.value
                });
            }
        });

        // Compare heap
        const heap1Addrs = new Set(snapshot1.heap.allocations.map(a => a.address));
        const heap2Addrs = new Set(snapshot2.heap.allocations.map(a => a.address));

        snapshot2.heap.allocations.forEach(alloc => {
            if (!heap1Addrs.has(alloc.address)) {
                diff.heapChanges.push({
                    type: 'allocation',
                    address: alloc.address,
                    size: alloc.size
                });
            }
        });

        snapshot1.heap.allocations.forEach(alloc => {
            if (!heap2Addrs.has(alloc.address)) {
                diff.heapChanges.push({
                    type: 'deallocation',
                    address: alloc.address,
                    size: alloc.size
                });
            }
        });

        // Compare stack
        if (snapshot1.stackFrames.length !== snapshot2.stackFrames.length) {
            diff.stackChanges.push({
                type: snapshot2.stackFrames.length > snapshot1.stackFrames.length
                    ? 'push'
                    : 'pop',
                depth: Math.abs(snapshot2.stackFrames.length - snapshot1.stackFrames.length)
            });
        }

        // Compare registers
        if (snapshot1.registers.pc !== snapshot2.registers.pc) {
            diff.registerChanges.push({
                register: 'pc',
                oldValue: snapshot1.registers.pc,
                newValue: snapshot2.registers.pc
            });
        }

        return diff;
    }

    /**
     * Clear all recorded history
     */
    public clearHistory(): void {
        this.snapshots = [];
        this.currentSnapshotIndex = -1;
    }

    /**
     * Get execution timeline for visualization
     */
    public getTimeline(): TimelineEntry[] {
        return this.snapshots.map((snapshot, index) => ({
            sequenceNumber: snapshot.sequenceNumber,
            timestamp: snapshot.timestamp,
            line: snapshot.stackFrames[0]?.line || 0,
            source: snapshot.stackFrames[0]?.source || '',
            isCurrent: index === this.currentSnapshotIndex,
            isBreakpoint: this.isAtBreakpoint(snapshot)
        }));
    }

    /**
     * Enable/disable recording
     */
    public setRecording(enabled: boolean): void {
        this.recordingEnabled = enabled;
    }

    /**
     * Get statistics about recorded history
     */
    public getStatistics(): TimelineStatistics {
        const memoryUsage = this.snapshots.reduce(
            (sum, snapshot) => sum + snapshot.heap.totalSize,
            0
        );

        return {
            totalSnapshots: this.snapshots.length,
            currentPosition: this.currentSnapshotIndex,
            memoryUsage,
            timeRange: {
                start: this.snapshots[0]?.timestamp || 0,
                end: this.snapshots[this.snapshots.length - 1]?.timestamp || 0
            },
            canStepBack: this.currentSnapshotIndex > 0,
            canStepForward: this.currentSnapshotIndex < this.snapshots.length - 1
        };
    }

    /**
     * Export history to file
     */
    public exportHistory(): string {
        return JSON.stringify({
            version: '1.0',
            snapshots: this.snapshots,
            currentIndex: this.currentSnapshotIndex,
            exportedAt: new Date().toISOString()
        }, null, 2);
    }

    /**
     * Import history from file
     */
    public importHistory(data: string): boolean {
        try {
            const imported = JSON.parse(data);
            if (imported.version !== '1.0') {
                return false;
            }

            this.snapshots = imported.snapshots;
            this.currentSnapshotIndex = imported.currentIndex;
            return true;
        } catch (error) {
            return false;
        }
    }

    private isAtBreakpoint(snapshot: ExecutionSnapshot): boolean {
        // In real implementation, check against actual breakpoints
        // For now, return false
        return false;
    }
}

export interface SnapshotDiff {
    variableChanges: {
        name: string;
        oldValue: string;
        newValue: string;
    }[];
    heapChanges: {
        type: 'allocation' | 'deallocation';
        address: string;
        size: number;
    }[];
    stackChanges: {
        type: 'push' | 'pop';
        depth: number;
    }[];
    registerChanges: {
        register: string;
        oldValue: number;
        newValue: number;
    }[];
}

export interface TimelineEntry {
    sequenceNumber: number;
    timestamp: number;
    line: number;
    source: string;
    isCurrent: boolean;
    isBreakpoint: boolean;
}

export interface TimelineStatistics {
    totalSnapshots: number;
    currentPosition: number;
    memoryUsage: number;
    timeRange: {
        start: number;
        end: number;
    };
    canStepBack: boolean;
    canStepForward: boolean;
}
