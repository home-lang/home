import * as fs from 'fs/promises';
import * as path from 'path';
import * as vscode from 'vscode';

/**
 * CPU Profiler
 *
 * Samples CPU usage and generates flame graphs for performance analysis.
 * Tracks function call times, call counts, and generates Chrome DevTools compatible profiles.
 */

export interface CPUSample {
    timestamp: number;
    stackTrace: string[];
    threadId: number;
}

export interface FunctionProfile {
    name: string;
    file: string;
    line: number;
    selfTime: number;      // Time spent in function itself
    totalTime: number;     // Time spent including children
    callCount: number;
    children: Map<string, FunctionProfile>;
}

export interface FlameGraphNode {
    name: string;
    value: number;        // Time in microseconds
    children: FlameGraphNode[];
}

export interface ChromeDevToolsProfile {
    nodes: ChromeNode[];
    startTime: number;
    endTime: number;
    samples: number[];
    timeDeltas: number[];
}

export interface ChromeNode {
    id: number;
    callFrame: {
        functionName: string;
        scriptId: string;
        url: string;
        lineNumber: number;
        columnNumber: number;
    };
    hitCount: number;
    children?: number[];
    parent?: number;
}

export class CPUProfiler {
    private samples: CPUSample[] = [];
    private _isRunning = false;
    private _startTime = 0;
    private readonly _outputChannel: vscode.OutputChannel;
    private sampleInterval = 1; // milliseconds
    private readonly functionProfiles = new Map<string, FunctionProfile>();

    constructor() {
        this._outputChannel = vscode.window.createOutputChannel('Home CPU Profiler');
    }

    /**
     * Start CPU profiling
     */
    public start(sampleIntervalMs: number = 1): void {
        if (this._isRunning) {
            vscode.window.showWarningMessage('CPU profiler is already running');
            return;
        }

        this._isRunning = true;
        this._startTime = Date.now();
        this.samples = [];
        this.functionProfiles.clear();
        this.sampleInterval = sampleIntervalMs;

        this._outputChannel.clear();
        this._outputChannel.appendLine('CPU profiler started');
        this._outputChannel.appendLine(`Sample interval: ${sampleIntervalMs}ms`);
        this._outputChannel.show();
    }

    /**
     * Stop CPU profiling
     */
    public stop(): void {
        if (!this._isRunning) {
            vscode.window.showWarningMessage('CPU profiler is not running');
            return;
        }

        this._isRunning = false;
        const duration = Date.now() - this._startTime;

        this._outputChannel.appendLine('\nCPU profiling stopped');
        this._outputChannel.appendLine(`Duration: ${duration}ms`);
        this._outputChannel.appendLine(`Total samples: ${this.samples.length}`);
        this._outputChannel.appendLine(
            `Sample rate: ${(this.samples.length / (duration / 1000)).toFixed(2)} samples/sec`
        );

        this.analyzeSamples();
    }

    /**
     * Record a CPU sample
     */
    public recordSample(stackTrace: string[], threadId: number = 0): void {
        if (!this._isRunning) return;

        this.samples.push({
            timestamp: Date.now(),
            stackTrace,
            threadId
        });
    }

    /**
     * Analyze collected samples
     */
    private analyzeSamples(): void {
        for (const sample of this.samples) {
            this.processSample(sample);
        }

        this._outputChannel.appendLine('\nTop functions by total time:');
        const sorted = Array.from(this.functionProfiles.values())
            .sort((a, b) => b.totalTime - a.totalTime)
            .slice(0, 10);

        for (const profile of sorted) {
            this._outputChannel.appendLine(
                `  ${profile.name}: ${profile.totalTime.toFixed(2)}ms (${profile.callCount} calls)`
            );
        }
    }

    /**
     * Process a single sample
     */
    private processSample(sample: CPUSample): void {
        // Build call tree from stack trace
        for (let i = 0; i < sample.stackTrace.length; i++) {
            const funcName = sample.stackTrace[i];
            const key = this.getFunctionKey(funcName, i);

            let profile = this.functionProfiles.get(key);
            if (!profile) {
                profile = {
                    name: funcName,
                    file: '',
                    line: 0,
                    selfTime: 0,
                    totalTime: 0,
                    callCount: 0,
                    children: new Map()
                };
                this.functionProfiles.set(key, profile);
            }

            profile.callCount++;
            profile.totalTime += this.sampleInterval;

            // Self time only for the top of the stack
            if (i === 0) {
                profile.selfTime += this.sampleInterval;
            }
        }
    }

    /**
     * Generate flame graph data
     */
    public generateFlameGraph(): FlameGraphNode {
        const root: FlameGraphNode = {
            name: 'root',
            value: 0,
            children: []
        };

        // Build tree from samples
        for (const sample of this.samples) {
            this.addSampleToFlameGraph(root, sample.stackTrace.slice().reverse());
        }

        // Calculate values
        this.calculateFlameGraphValues(root);

        return root;
    }

    /**
     * Add a sample to flame graph tree
     */
    private addSampleToFlameGraph(
        node: FlameGraphNode,
        stackTrace: string[]
    ): void {
        if (stackTrace.length === 0) return;

        const funcName = stackTrace[0];
        let child = node.children.find(c => c.name === funcName);

        if (!child) {
            child = {
                name: funcName,
                value: 0,
                children: []
            };
            node.children.push(child);
        }

        if (stackTrace.length > 1) {
            this.addSampleToFlameGraph(child, stackTrace.slice(1));
        }
    }

    /**
     * Calculate flame graph values (time spent)
     */
    private calculateFlameGraphValues(node: FlameGraphNode): number {
        if (node.children.length === 0) {
            node.value = this.sampleInterval;
            return node.value;
        }

        let total = 0;
        for (const child of node.children) {
            total += this.calculateFlameGraphValues(child);
        }

        node.value = total;
        return total;
    }

    /**
     * Generate flame graph HTML
     */
    public async generateFlameGraphHTML(): Promise<void> {
        const flameGraph = this.generateFlameGraph();
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];

        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        const reportPath = path.join(
            workspaceFolder.uri.fsPath,
            'ion-flamegraph.html'
        );

        const html = this.getFlameGraphHTML(flameGraph);
        await fs.writeFile(reportPath, html);

        this._outputChannel.appendLine(`\nFlame graph saved to ${reportPath}`);

        const openReport = await vscode.window.showInformationMessage(
            'Flame graph generated',
            'Open Flame Graph'
        );

        if (openReport === 'Open Flame Graph') {
            const uri = vscode.Uri.file(reportPath);
            await vscode.commands.executeCommand('vscode.open', uri);
        }
    }

    /**
     * Export to Chrome DevTools format
     */
    public exportToChromeDevTools(): ChromeDevToolsProfile {
        const nodes: ChromeNode[] = [];
        const nodeMap = new Map<string, number>();
        let nodeId = 1;

        // Build node tree
        for (const [key, profile] of this.functionProfiles) {
            nodes.push({
                id: nodeId,
                callFrame: {
                    functionName: profile.name,
                    scriptId: '0',
                    url: profile.file,
                    lineNumber: profile.line,
                    columnNumber: 0
                },
                hitCount: profile.callCount,
                children: []
            });
            nodeMap.set(key, nodeId);
            nodeId++;
        }

        // Build samples and time deltas. Chrome DevTools expects all timestamps
        // in microseconds; our internal samples track ms via Date.now().
        const samples: number[] = [];
        const timeDeltas: number[] = [];
        const lastTimestamp = this.samples[this.samples.length - 1]?.timestamp ?? this._startTime;

        for (let i = 0; i < this.samples.length; i++) {
            const sample = this.samples[i];
            const funcName = sample.stackTrace[0] || 'unknown';
            const key = this.getFunctionKey(funcName, 0);
            const id = nodeMap.get(key) ?? 0;

            samples.push(id);

            const prevTimestamp = i === 0 ? this._startTime : this.samples[i - 1].timestamp;
            timeDeltas.push((sample.timestamp - prevTimestamp) * 1000);
        }

        return {
            nodes,
            startTime: this._startTime * 1000,
            endTime: lastTimestamp * 1000,
            samples,
            timeDeltas,
        };
    }

    /**
     * Save Chrome DevTools profile
     */
    public async saveChromeProfile(): Promise<void> {
        const profile = this.exportToChromeDevTools();
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];

        if (!workspaceFolder) {
            vscode.window.showErrorMessage('No workspace folder open');
            return;
        }

        const profilePath = path.join(
            workspaceFolder.uri.fsPath,
            'ion-cpu-profile.json'
        );

        await fs.writeFile(profilePath, JSON.stringify(profile, null, 2));

        this._outputChannel.appendLine(`\nChrome profile saved to ${profilePath}`);

        const openInfo = await vscode.window.showInformationMessage(
            'Chrome DevTools profile saved',
            'Open in Chrome DevTools'
        );

        if (openInfo === 'Open in Chrome DevTools') {
            vscode.window.showInformationMessage(
                'Open Chrome DevTools, go to Performance tab, and load the profile file'
            );
        }
    }

    /**
     * Get function key for profiling
     */
    private getFunctionKey(funcName: string, depth: number): string {
        return `${funcName}@${depth}`;
    }

    /**
     * Generate flame graph HTML
     */
    private getFlameGraphHTML(flameGraph: FlameGraphNode): string {
        // Escape '<' so a function name containing "</script>" can't break out of the inline <script>.
        const flameGraphData = JSON.stringify(flameGraph).replace(/</g, '\\u003c');

        return `
<!DOCTYPE html>
<html>
<head>
    <title>Home CPU Flame Graph</title>
    <style>
        body {
            margin: 0;
            padding: 20px;
            font-family: monospace;
            background: #1e1e1e;
            color: #fff;
        }
        h1 { margin-bottom: 20px; }
        #flamegraph {
            width: 100%;
            height: 600px;
            border: 1px solid #444;
        }
        .frame {
            cursor: pointer;
            stroke: #000;
            stroke-width: 0.5;
        }
        .frame:hover {
            stroke: #fff;
            stroke-width: 2;
        }
        text {
            pointer-events: none;
            font-size: 12px;
        }
        #info {
            margin-top: 20px;
            padding: 10px;
            background: #2d2d2d;
            border-radius: 4px;
        }
    </style>
</head>
<body>
    <h1>Home CPU Flame Graph</h1>
    <div id="info">Click on a frame to zoom. Ctrl+Click to reset.</div>
    <svg id="flamegraph"></svg>

    <script>
        const data = ${flameGraphData};
        const width = document.getElementById('flamegraph').clientWidth;
        const height = 600;
        const colors = [
            '#e74c3c', '#3498db', '#2ecc71', '#f39c12',
            '#9b59b6', '#1abc9c', '#34495e', '#e67e22'
        ];

        function getColor(name) {
            let hash = 0;
            for (let i = 0; i < name.length; i++) {
                hash = name.charCodeAt(i) + ((hash << 5) - hash);
            }
            return colors[Math.abs(hash) % colors.length];
        }

        function renderFlameGraph(node, x, y, width, depth = 0) {
            const svg = document.getElementById('flamegraph');
            const rectHeight = 20;

            if (width < 1) return;

            const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
            rect.setAttribute('x', x);
            rect.setAttribute('y', y);
            rect.setAttribute('width', width);
            rect.setAttribute('height', rectHeight);
            rect.setAttribute('fill', getColor(node.name));
            rect.classList.add('frame');

            const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
            text.setAttribute('x', x + 4);
            text.setAttribute('y', y + 14);
            text.setAttribute('fill', '#fff');
            text.textContent = width > 50 ? node.name : '';

            rect.addEventListener('click', (e) => {
                if (e.ctrlKey) {
                    location.reload();
                } else {
                    zoomToNode(node);
                }
            });

            svg.appendChild(rect);
            svg.appendChild(text);

            // Render children
            let childX = x;
            const totalValue = node.children.reduce((sum, c) => sum + c.value, 0);

            for (const child of node.children) {
                const childWidth = (child.value / totalValue) * width;
                renderFlameGraph(child, childX, y + rectHeight, childWidth, depth + 1);
                childX += childWidth;
            }
        }

        function zoomToNode(node) {
            const svg = document.getElementById('flamegraph');
            svg.innerHTML = '';
            renderFlameGraph(node, 0, 0, width);
        }

        // Initial render
        renderFlameGraph(data, 0, 0, width);
    </script>
</body>
</html>
        `;
    }

    public dispose(): void {
        this._outputChannel.dispose();
    }
}
