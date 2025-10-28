import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Memory Profiler
 *
 * Tracks memory allocations, deallocations, and provides detailed memory analysis.
 * Detects memory leaks, fragmentation, and provides heap snapshots.
 */

export interface MemoryAllocation {
    address: string;
    size: number;
    type: string;
    timestamp: number;
    stackTrace: string[];
    freed: boolean;
    freedAt?: number;
}

export interface HeapSnapshot {
    timestamp: number;
    totalAllocated: number;
    totalFreed: number;
    currentUsage: number;
    allocations: MemoryAllocation[];
    fragmentation: number;
}

export interface MemoryLeak {
    allocation: MemoryAllocation;
    age: number; // milliseconds since allocation
    suspicionLevel: 'low' | 'medium' | 'high';
    reason: string;
}

export interface MemoryStatistics {
    totalAllocations: number;
    totalDeallocations: number;
    currentAllocations: number;
    peakMemoryUsage: number;
    averageAllocationSize: number;
    allocationsByType: Map<string, number>;
    leaks: MemoryLeak[];
}

export class MemoryProfiler {
    private allocations: Map<string, MemoryAllocation> = new Map();
    private allocationHistory: MemoryAllocation[] = [];
    private snapshots: HeapSnapshot[] = [];
    private _outputChannel: vscode.OutputChannel;
    private _isRunning: boolean = false;
    private _startTime: number = 0;
    private _peakUsage: number = 0;

    constructor() {
        this._outputChannel = vscode.window.createOutputChannel('Home Memory Profiler');
    }

    /**
     * Start memory profiling
     */
    public start(): void {
        if (this._isRunning) {
            vscode.window.showWarningMessage('Memory profiler is already running');
            return;
        }

        this._isRunning = true;
        this._startTime = Date.now();
        this.allocations.clear();
        this.allocationHistory = [];
        this.snapshots = [];
        this._peakUsage = 0;

        this._outputChannel.clear();
        this._outputChannel.appendLine('Memory profiler started');
        this._outputChannel.show();
    }

    /**
     * Stop memory profiling
     */
    public stop(): MemoryStatistics {
        if (!this._isRunning) {
            vscode.window.showWarningMessage('Memory profiler is not running');
            return this.getStatistics();
        }

        this._isRunning = false;
        const stats = this.getStatistics();

        this._outputChannel.appendLine('\nMemory profiling stopped');
        this._outputChannel.appendLine(`Duration: ${Date.now() - this._startTime}ms`);
        this._outputChannel.appendLine(`Total allocations: ${stats.totalAllocations}`);
        this._outputChannel.appendLine(`Total deallocations: ${stats.totalDeallocations}`);
        this._outputChannel.appendLine(`Current allocations: ${stats.currentAllocations}`);
        this._outputChannel.appendLine(`Peak memory usage: ${this.formatBytes(stats.peakMemoryUsage)}`);

        if (stats.leaks.length > 0) {
            this._outputChannel.appendLine(`\n⚠️  Potential memory leaks detected: ${stats.leaks.length}`);
        }

        return stats;
    }

    /**
     * Record a memory allocation
     */
    public recordAllocation(
        address: string,
        size: number,
        type: string,
        stackTrace: string[]
    ): void {
        if (!this._isRunning) return;

        const allocation: MemoryAllocation = {
            address,
            size,
            type,
            timestamp: Date.now(),
            stackTrace,
            freed: false
        };

        this.allocations.set(address, allocation);
        this.allocationHistory.push(allocation);

        // Update peak usage
        const currentUsage = this.getCurrentUsage();
        if (currentUsage > this._peakUsage) {
            this._peakUsage = currentUsage;
        }

        this._outputChannel.appendLine(
            `[ALLOC] ${address} ${this.formatBytes(size)} ${type}`
        );
    }

    /**
     * Record a memory deallocation
     */
    public recordDeallocation(address: string): void {
        if (!this._isRunning) return;

        const allocation = this.allocations.get(address);
        if (allocation) {
            allocation.freed = true;
            allocation.freedAt = Date.now();
            this.allocations.delete(address);

            this._outputChannel.appendLine(
                `[FREE]  ${address} ${this.formatBytes(allocation.size)}`
            );
        } else {
            this._outputChannel.appendLine(
                `[WARN]  Attempted to free unknown address: ${address}`
            );
        }
    }

    /**
     * Take a heap snapshot
     */
    public takeSnapshot(): HeapSnapshot {
        const currentAllocations = Array.from(this.allocations.values());
        const totalAllocated = this.allocationHistory.reduce(
            (sum, alloc) => sum + alloc.size,
            0
        );
        const totalFreed = this.allocationHistory
            .filter(alloc => alloc.freed)
            .reduce((sum, alloc) => sum + alloc.size, 0);

        const snapshot: HeapSnapshot = {
            timestamp: Date.now(),
            totalAllocated,
            totalFreed,
            currentUsage: this.getCurrentUsage(),
            allocations: currentAllocations,
            fragmentation: this.calculateFragmentation()
        };

        this.snapshots.push(snapshot);
        return snapshot;
    }

    /**
     * Compare two heap snapshots
     */
    public compareSnapshots(
        snapshot1: HeapSnapshot,
        snapshot2: HeapSnapshot
    ): SnapshotComparison {
        const addrs1 = new Set(snapshot1.allocations.map(a => a.address));
        const addrs2 = new Set(snapshot2.allocations.map(a => a.address));

        const newAllocations = snapshot2.allocations.filter(
            a => !addrs1.has(a.address)
        );
        const freedAllocations = snapshot1.allocations.filter(
            a => !addrs2.has(a.address)
        );

        return {
            timeDelta: snapshot2.timestamp - snapshot1.timestamp,
            usageDelta: snapshot2.currentUsage - snapshot1.currentUsage,
            newAllocations,
            freedAllocations,
            newAllocationCount: newAllocations.length,
            freedAllocationCount: freedAllocations.length,
            netAllocationCount: newAllocations.length - freedAllocations.length
        };
    }

    /**
     * Detect potential memory leaks
     */
    public detectLeaks(): MemoryLeak[] {
        const now = Date.now();
        const leaks: MemoryLeak[] = [];

        for (const allocation of this.allocations.values()) {
            const age = now - allocation.timestamp;

            // Heuristics for leak detection
            let suspicionLevel: 'low' | 'medium' | 'high' = 'low';
            let reason = '';

            if (age > 60000) { // > 1 minute
                suspicionLevel = 'high';
                reason = 'Long-lived allocation (>1 minute)';
            } else if (age > 30000) { // > 30 seconds
                suspicionLevel = 'medium';
                reason = 'Moderately long-lived allocation (>30 seconds)';
            } else if (allocation.size > 1024 * 1024) { // > 1MB
                suspicionLevel = 'medium';
                reason = 'Large allocation (>1MB)';
            }

            if (suspicionLevel !== 'low') {
                leaks.push({
                    allocation,
                    age,
                    suspicionLevel,
                    reason
                });
            }
        }

        return leaks.sort((a, b) => {
            const levelOrder = { high: 3, medium: 2, low: 1 };
            return levelOrder[b.suspicionLevel] - levelOrder[a.suspicionLevel];
        });
    }

    /**
     * Get memory statistics
     */
    public getStatistics(): MemoryStatistics {
        const allocationsByType = new Map<string, number>();

        for (const alloc of this.allocationHistory) {
            const count = allocationsByType.get(alloc.type) || 0;
            allocationsByType.set(alloc.type, count + 1);
        }

        const totalSize = this.allocationHistory.reduce(
            (sum, alloc) => sum + alloc.size,
            0
        );

        return {
            totalAllocations: this.allocationHistory.length,
            totalDeallocations: this.allocationHistory.filter(a => a.freed).length,
            currentAllocations: this.allocations.size,
            peakMemoryUsage: this._peakUsage,
            averageAllocationSize:
                this.allocationHistory.length > 0
                    ? totalSize / this.allocationHistory.length
                    : 0,
            allocationsByType,
            leaks: this.detectLeaks()
        };
    }

    /**
     * Generate memory report
     */
    public async generateReport(): Promise<void> {
        const stats = this.getStatistics();
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];

        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        const reportPath = path.join(
            workspaceFolder.uri.fsPath,
            'ion-memory-report.html'
        );

        const html = this.generateReportHTML(stats);
        fs.writeFileSync(reportPath, html);

        this._outputChannel.appendLine(`\nReport saved to ${reportPath}`);

        const openReport = await vscode.window.showInformationMessage(
            'Memory report generated',
            'Open Report'
        );

        if (openReport === 'Open Report') {
            const uri = vscode.Uri.file(reportPath);
            await vscode.commands.executeCommand('vscode.open', uri);
        }
    }

    /**
     * Get current memory usage
     */
    private getCurrentUsage(): number {
        return Array.from(this.allocations.values()).reduce(
            (sum, alloc) => sum + alloc.size,
            0
        );
    }

    /**
     * Calculate heap fragmentation
     */
    private calculateFragmentation(): number {
        // Simplified fragmentation calculation
        // In real implementation, would analyze actual memory layout
        const allocations = Array.from(this.allocations.values());
        if (allocations.length === 0) return 0;

        const sizes = allocations.map(a => a.size).sort((a, b) => a - b);
        const variance =
            sizes.reduce((sum, size) => {
                const mean = this.getCurrentUsage() / sizes.length;
                return sum + Math.pow(size - mean, 2);
            }, 0) / sizes.length;

        return Math.sqrt(variance) / (this.getCurrentUsage() / sizes.length);
    }

    /**
     * Format bytes for display
     */
    private formatBytes(bytes: number): string {
        if (bytes === 0) return '0 B';

        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));

        return `${parseFloat((bytes / Math.pow(k, i)).toFixed(2))} ${sizes[i]}`;
    }

    /**
     * Generate HTML report
     */
    private generateReportHTML(stats: MemoryStatistics): string {
        const typeChart = Array.from(stats.allocationsByType.entries())
            .map(([type, count]) => `<tr><td>${type}</td><td>${count}</td></tr>`)
            .join('');

        const leaksList = stats.leaks
            .map(
                leak => `
                <tr class="${leak.suspicionLevel}">
                    <td>${leak.allocation.address}</td>
                    <td>${this.formatBytes(leak.allocation.size)}</td>
                    <td>${leak.allocation.type}</td>
                    <td>${(leak.age / 1000).toFixed(2)}s</td>
                    <td>${leak.suspicionLevel}</td>
                    <td>${leak.reason}</td>
                </tr>
            `
            )
            .join('');

        return `
<!DOCTYPE html>
<html>
<head>
    <title>Home Memory Profiler Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            padding: 20px;
            max-width: 1200px;
            margin: 0 auto;
        }
        h1 { color: #333; }
        h2 { color: #666; margin-top: 30px; }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 20px 0;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 12px;
            text-align: left;
        }
        th {
            background-color: #f2f2f2;
            font-weight: bold;
        }
        tr:hover { background-color: #f5f5f5; }
        .high { background-color: #ffebee; }
        .medium { background-color: #fff3e0; }
        .low { background-color: #f1f8e9; }
        .stat-box {
            display: inline-block;
            padding: 20px;
            margin: 10px;
            background: #f5f5f5;
            border-radius: 8px;
            min-width: 200px;
        }
        .stat-label { font-size: 12px; color: #666; }
        .stat-value { font-size: 24px; font-weight: bold; color: #333; }
    </style>
</head>
<body>
    <h1>Home Memory Profiler Report</h1>
    <p>Generated: ${new Date().toISOString()}</p>

    <h2>Summary</h2>
    <div>
        <div class="stat-box">
            <div class="stat-label">Total Allocations</div>
            <div class="stat-value">${stats.totalAllocations}</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Total Deallocations</div>
            <div class="stat-value">${stats.totalDeallocations}</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Current Allocations</div>
            <div class="stat-value">${stats.currentAllocations}</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Peak Memory Usage</div>
            <div class="stat-value">${this.formatBytes(stats.peakMemoryUsage)}</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Avg Allocation Size</div>
            <div class="stat-value">${this.formatBytes(stats.averageAllocationSize)}</div>
        </div>
    </div>

    <h2>Allocations by Type</h2>
    <table>
        <thead>
            <tr>
                <th>Type</th>
                <th>Count</th>
            </tr>
        </thead>
        <tbody>
            ${typeChart}
        </tbody>
    </table>

    <h2>Potential Memory Leaks</h2>
    ${
            stats.leaks.length > 0
                ? `
        <table>
            <thead>
                <tr>
                    <th>Address</th>
                    <th>Size</th>
                    <th>Type</th>
                    <th>Age</th>
                    <th>Suspicion</th>
                    <th>Reason</th>
                </tr>
            </thead>
            <tbody>
                ${leaksList}
            </tbody>
        </table>
    `
                : '<p>No memory leaks detected!</p>'
        }
</body>
</html>
        `;
    }

    public dispose(): void {
        this._outputChannel.dispose();
    }
}

export interface SnapshotComparison {
    timeDelta: number;
    usageDelta: number;
    newAllocations: MemoryAllocation[];
    freedAllocations: MemoryAllocation[];
    newAllocationCount: number;
    freedAllocationCount: number;
    netAllocationCount: number;
}
