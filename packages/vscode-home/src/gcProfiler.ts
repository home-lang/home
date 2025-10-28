import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Garbage Collection Profiler
 *
 * Tracks GC events, analyzes collection patterns, and identifies performance issues.
 * Monitors heap usage, collection times, and object lifetimes.
 */

export interface GCEvent {
    timestamp: number;
    type: GCType;
    generation: number;
    heapSizeBefore: number;
    heapSizeAfter: number;
    duration: number;
    objectsCollected: number;
    objectsSurvived: number;
    reason: string;
}

export enum GCType {
    Minor = 'minor',      // Young generation
    Major = 'major',      // Full collection
    Incremental = 'incremental'
}

export interface ObjectLifetime {
    address: string;
    type: string;
    allocatedAt: number;
    collectedAt?: number;
    generation: number;
    size: number;
}

export interface GCStatistics {
    totalCollections: number;
    minorCollections: number;
    majorCollections: number;
    totalPauseTime: number;
    averagePauseTime: number;
    maxPauseTime: number;
    totalBytesCollected: number;
    heapGrowth: number;
    collectionFrequency: number; // collections per second
}

export interface GenerationStats {
    generation: number;
    collections: number;
    totalSize: number;
    objectCount: number;
    survivalRate: number;
}

export class GCProfiler {
    private events: GCEvent[] = [];
    private objectLifetimes: Map<string, ObjectLifetime> = new Map();
    private _isRunning: boolean = false;
    private _startTime: number = 0;
    private _outputChannel: vscode.OutputChannel;
    private heapHistory: HeapSnapshot[] = [];

    constructor() {
        this._outputChannel = vscode.window.createOutputChannel('Home GC Profiler');
    }

    /**
     * Start GC profiling
     */
    public start(): void {
        if (this._isRunning) {
            vscode.window.showWarningMessage('GC profiler is already running');
            return;
        }

        this._isRunning = true;
        this._startTime = Date.now();
        this.events = [];
        this.objectLifetimes.clear();
        this.heapHistory = [];

        this._outputChannel.clear();
        this._outputChannel.appendLine('GC profiler started');
        this._outputChannel.show();
    }

    /**
     * Stop GC profiling
     */
    public stop(): GCStatistics {
        if (!this._isRunning) {
            vscode.window.showWarningMessage('GC profiler is not running');
            return this.getStatistics();
        }

        this._isRunning = false;
        const stats = this.getStatistics();

        this._outputChannel.appendLine('\nGC profiling stopped');
        this._outputChannel.appendLine(`Total collections: ${stats.totalCollections}`);
        this._outputChannel.appendLine(`Minor collections: ${stats.minorCollections}`);
        this._outputChannel.appendLine(`Major collections: ${stats.majorCollections}`);
        this._outputChannel.appendLine(
            `Total pause time: ${stats.totalPauseTime.toFixed(2)}ms`
        );
        this._outputChannel.appendLine(
            `Average pause time: ${stats.averagePauseTime.toFixed(2)}ms`
        );
        this._outputChannel.appendLine(
            `Max pause time: ${stats.maxPauseTime.toFixed(2)}ms`
        );

        return stats;
    }

    /**
     * Record a GC event
     */
    public recordGCEvent(event: GCEvent): void {
        if (!this._isRunning) return;

        this.events.push(event);

        this._outputChannel.appendLine(
            `[GC] ${event.type} gen${event.generation} ${event.duration.toFixed(2)}ms ` +
            `${this.formatBytes(event.heapSizeBefore)} → ${this.formatBytes(event.heapSizeAfter)} ` +
            `(-${this.formatBytes(event.heapSizeBefore - event.heapSizeAfter)})`
        );

        // Record heap snapshot
        this.heapHistory.push({
            timestamp: event.timestamp,
            size: event.heapSizeAfter,
            generation: event.generation
        });
    }

    /**
     * Record object allocation
     */
    public recordObjectAllocation(
        address: string,
        type: string,
        generation: number,
        size: number
    ): void {
        if (!this._isRunning) return;

        this.objectLifetimes.set(address, {
            address,
            type,
            allocatedAt: Date.now(),
            generation,
            size
        });
    }

    /**
     * Record object collection
     */
    public recordObjectCollection(address: string): void {
        if (!this._isRunning) return;

        const lifetime = this.objectLifetimes.get(address);
        if (lifetime) {
            lifetime.collectedAt = Date.now();
        }
    }

    /**
     * Get GC statistics
     */
    public getStatistics(): GCStatistics {
        const duration = Date.now() - this._startTime;

        const minorCollections = this.events.filter(
            e => e.type === GCType.Minor
        ).length;
        const majorCollections = this.events.filter(
            e => e.type === GCType.Major
        ).length;

        const totalPauseTime = this.events.reduce(
            (sum, e) => sum + e.duration,
            0
        );
        const maxPauseTime = Math.max(...this.events.map(e => e.duration), 0);

        const totalBytesCollected = this.events.reduce(
            (sum, e) => sum + (e.heapSizeBefore - e.heapSizeAfter),
            0
        );

        const heapGrowth =
            this.events.length > 0
                ? this.events[this.events.length - 1].heapSizeAfter -
                  this.events[0].heapSizeBefore
                : 0;

        return {
            totalCollections: this.events.length,
            minorCollections,
            majorCollections,
            totalPauseTime,
            averagePauseTime:
                this.events.length > 0 ? totalPauseTime / this.events.length : 0,
            maxPauseTime,
            totalBytesCollected,
            heapGrowth,
            collectionFrequency: (this.events.length / duration) * 1000
        };
    }

    /**
     * Get generation statistics
     */
    public getGenerationStats(): GenerationStats[] {
        const genMap = new Map<number, GenerationStats>();

        for (const event of this.events) {
            if (!genMap.has(event.generation)) {
                genMap.set(event.generation, {
                    generation: event.generation,
                    collections: 0,
                    totalSize: 0,
                    objectCount: 0,
                    survivalRate: 0
                });
            }

            const stats = genMap.get(event.generation)!;
            stats.collections++;
            stats.totalSize += event.heapSizeAfter;

            // Calculate survival rate
            if (event.objectsCollected + event.objectsSurvived > 0) {
                stats.survivalRate =
                    event.objectsSurvived /
                    (event.objectsCollected + event.objectsSurvived);
            }
        }

        return Array.from(genMap.values()).sort((a, b) => a.generation - b.generation);
    }

    /**
     * Analyze object lifetimes
     */
    public analyzeObjectLifetimes(): ObjectLifetimeAnalysis {
        const lifetimes: number[] = [];
        const typeLifetimes = new Map<string, number[]>();

        for (const obj of this.objectLifetimes.values()) {
            if (obj.collectedAt) {
                const lifetime = obj.collectedAt - obj.allocatedAt;
                lifetimes.push(lifetime);

                if (!typeLifetimes.has(obj.type)) {
                    typeLifetimes.set(obj.type, []);
                }
                typeLifetimes.get(obj.type)!.push(lifetime);
            }
        }

        const avgLifetime =
            lifetimes.length > 0
                ? lifetimes.reduce((a, b) => a + b, 0) / lifetimes.length
                : 0;

        const medianLifetime =
            lifetimes.length > 0
                ? lifetimes.sort((a, b) => a - b)[Math.floor(lifetimes.length / 2)]
                : 0;

        const typeAvgLifetimes = new Map<string, number>();
        for (const [type, times] of typeLifetimes) {
            const avg = times.reduce((a, b) => a + b, 0) / times.length;
            typeAvgLifetimes.set(type, avg);
        }

        return {
            averageLifetime: avgLifetime,
            medianLifetime: medianLifetime,
            shortLived: lifetimes.filter(l => l < 1000).length,
            longLived: lifetimes.filter(l => l > 60000).length,
            typeLifetimes: typeAvgLifetimes
        };
    }

    /**
     * Detect GC pressure
     */
    public detectGCPressure(): GCPressureAnalysis {
        const stats = this.getStatistics();
        const recentEvents = this.events.slice(-10);

        const highFrequency = stats.collectionFrequency > 10; // > 10 GCs per second
        const highPauseTime = stats.averagePauseTime > 100; // > 100ms average
        const rapidGrowth = stats.heapGrowth > 0 && stats.heapGrowth > 10 * 1024 * 1024; // > 10MB

        const frequentMinor = recentEvents.filter(e => e.type === GCType.Minor).length > 8;
        const frequentMajor = recentEvents.filter(e => e.type === GCType.Major).length > 2;

        const issues: string[] = [];
        let severity: 'low' | 'medium' | 'high' = 'low';

        if (highFrequency) {
            issues.push('High GC frequency');
            severity = 'high';
        }
        if (highPauseTime) {
            issues.push('Long GC pause times');
            severity = severity === 'high' ? 'high' : 'medium';
        }
        if (rapidGrowth) {
            issues.push('Rapid heap growth');
            severity = severity === 'high' ? 'high' : 'medium';
        }
        if (frequentMinor) {
            issues.push('Frequent minor collections');
        }
        if (frequentMajor) {
            issues.push('Frequent major collections');
            severity = 'high';
        }

        return {
            hasPressure: issues.length > 0,
            severity,
            issues,
            recommendations: this.generateRecommendations(issues)
        };
    }

    /**
     * Generate recommendations
     */
    private generateRecommendations(issues: string[]): string[] {
        const recommendations: string[] = [];

        if (issues.includes('High GC frequency')) {
            recommendations.push('Reduce object allocation rate');
            recommendations.push('Consider object pooling for frequently allocated types');
        }
        if (issues.includes('Long GC pause times')) {
            recommendations.push('Increase heap size');
            recommendations.push('Consider incremental GC mode');
        }
        if (issues.includes('Rapid heap growth')) {
            recommendations.push('Check for memory leaks');
            recommendations.push('Review object retention patterns');
        }
        if (issues.includes('Frequent major collections')) {
            recommendations.push('Increase young generation size');
            recommendations.push('Review object promotion patterns');
        }

        return recommendations;
    }

    /**
     * Generate GC report
     */
    public async generateReport(): Promise<void> {
        const stats = this.getStatistics();
        const genStats = this.getGenerationStats();
        const lifetimeAnalysis = this.analyzeObjectLifetimes();
        const pressure = this.detectGCPressure();

        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        const reportPath = path.join(
            workspaceFolder.uri.fsPath,
            'ion-gc-report.html'
        );

        const html = this.generateReportHTML(stats, genStats, lifetimeAnalysis, pressure);
        fs.writeFileSync(reportPath, html);

        this._outputChannel.appendLine(`\nReport saved to ${reportPath}`);

        const openReport = await vscode.window.showInformationMessage(
            'GC report generated',
            'Open Report'
        );

        if (openReport === 'Open Report') {
            const uri = vscode.Uri.file(reportPath);
            await vscode.commands.executeCommand('vscode.open', uri);
        }
    }

    /**
     * Format bytes
     */
    private formatBytes(bytes: number): string {
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return `${parseFloat((bytes / Math.pow(k, i)).toFixed(2))} ${sizes[i]}`;
    }

    /**
     * Generate HTML report
     */
    private generateReportHTML(
        stats: GCStatistics,
        genStats: GenerationStats[],
        lifetimeAnalysis: ObjectLifetimeAnalysis,
        pressure: GCPressureAnalysis
    ): string {
        return `
<!DOCTYPE html>
<html>
<head>
    <title>Home GC Profiler Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            padding: 20px;
            max-width: 1200px;
            margin: 0 auto;
        }
        h1 { color: #333; }
        h2 { color: #666; margin-top: 30px; }
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
        .alert {
            padding: 15px;
            margin: 20px 0;
            border-radius: 5px;
        }
        .alert.high { background: #ffebee; border-left: 4px solid #f44336; }
        .alert.medium { background: #fff3e0; border-left: 4px solid #ff9800; }
        .alert.low { background: #e8f5e9; border-left: 4px solid #4caf50; }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th, td {
            padding: 12px;
            border: 1px solid #ddd;
            text-align: left;
        }
        th { background: #f5f5f5; }
    </style>
</head>
<body>
    <h1>Home GC Profiler Report</h1>
    <p>Generated: ${new Date().toISOString()}</p>

    ${
            pressure.hasPressure
                ? `
    <div class="alert ${pressure.severity}">
        <h3>⚠️ GC Pressure Detected (${pressure.severity})</h3>
        <ul>
            ${pressure.issues.map(issue => `<li>${issue}</li>`).join('')}
        </ul>
        <h4>Recommendations:</h4>
        <ul>
            ${pressure.recommendations.map(rec => `<li>${rec}</li>`).join('')}
        </ul>
    </div>
    `
                : '<div class="alert low"><h3>✓ No GC pressure detected</h3></div>'
        }

    <h2>Summary</h2>
    <div>
        <div class="stat-box">
            <div class="stat-label">Total Collections</div>
            <div class="stat-value">${stats.totalCollections}</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Total Pause Time</div>
            <div class="stat-value">${stats.totalPauseTime.toFixed(2)}ms</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Avg Pause Time</div>
            <div class="stat-value">${stats.averagePauseTime.toFixed(2)}ms</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Max Pause Time</div>
            <div class="stat-value">${stats.maxPauseTime.toFixed(2)}ms</div>
        </div>
    </div>

    <h2>Generation Statistics</h2>
    <table>
        <thead>
            <tr>
                <th>Generation</th>
                <th>Collections</th>
                <th>Survival Rate</th>
            </tr>
        </thead>
        <tbody>
            ${genStats
                .map(
                    gen => `
                <tr>
                    <td>Gen ${gen.generation}</td>
                    <td>${gen.collections}</td>
                    <td>${(gen.survivalRate * 100).toFixed(1)}%</td>
                </tr>
            `
                )
                .join('')}
        </tbody>
    </table>

    <h2>Object Lifetimes</h2>
    <div>
        <div class="stat-box">
            <div class="stat-label">Average Lifetime</div>
            <div class="stat-value">${(lifetimeAnalysis.averageLifetime / 1000).toFixed(2)}s</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Short-Lived Objects</div>
            <div class="stat-value">${lifetimeAnalysis.shortLived}</div>
        </div>
        <div class="stat-box">
            <div class="stat-label">Long-Lived Objects</div>
            <div class="stat-value">${lifetimeAnalysis.longLived}</div>
        </div>
    </div>
</body>
</html>
        `;
    }

    public dispose(): void {
        this._outputChannel.dispose();
    }
}

interface HeapSnapshot {
    timestamp: number;
    size: number;
    generation: number;
}

interface ObjectLifetimeAnalysis {
    averageLifetime: number;
    medianLifetime: number;
    shortLived: number;
    longLived: number;
    typeLifetimes: Map<string, number>;
}

interface GCPressureAnalysis {
    hasPressure: boolean;
    severity: 'low' | 'medium' | 'high';
    issues: string[];
    recommendations: string[];
}
