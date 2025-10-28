import {
    LoggingDebugSession,
    InitializedEvent,
    TerminatedEvent,
    StoppedEvent,
    BreakpointEvent,
    OutputEvent,
    Thread,
    StackFrame,
    Scope,
    Source,
    Handles,
    Breakpoint
} from 'vscode-debugadapter';
import { DebugProtocol } from 'vscode-debugprotocol';
import { spawn, ChildProcess } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';

interface LaunchRequestArguments extends DebugProtocol.LaunchRequestArguments {
    program: string;
    args?: string[];
    cwd?: string;
    stopOnEntry?: boolean;
    trace?: boolean;
    profiler?: boolean;
}

interface AttachRequestArguments extends DebugProtocol.AttachRequestArguments {
    processId: number;
    trace?: boolean;
}

interface DebuggerState {
    stackFrames: StackFrameData[];
    variables: Map<number, VariableData[]>;
    currentLine: number;
    currentFile: string;
}

interface StackFrameData {
    id: number;
    name: string;
    file: string;
    line: number;
    column: number;
    environmentId: number;
}

interface VariableData {
    name: string;
    value: string;
    type: string;
    variablesReference: number;
}

export class HomeDebugSession extends LoggingDebugSession {
    private static THREAD_ID = 1;

    private _variableHandles = new Handles<VariableData[]>();
    private _scopeHandles = new Handles<number>(); // Maps to environment/frame ID
    private _ionProcess: ChildProcess | undefined;
    private _breakpoints = new Map<string, DebugProtocol.Breakpoint[]>();
    private _profilerEnabled = false;
    private _profilerData: any[] = [];
    private _debuggerState: DebuggerState = {
        stackFrames: [],
        variables: new Map(),
        currentLine: 0,
        currentFile: ''
    };
    private _debugOutputBuffer: string = '';

    public constructor() {
        super("ion-debug.txt");
        this.setDebuggerLinesStartAt1(true);
        this.setDebuggerColumnsStartAt1(true);
    }

    protected initializeRequest(
        response: DebugProtocol.InitializeResponse,
        args: DebugProtocol.InitializeRequestArguments
    ): void {
        // Build and return the capabilities of this debug adapter
        response.body = response.body || {};

        // The adapter implements the configurationDoneRequest
        response.body.supportsConfigurationDoneRequest = true;

        // Make VS Code use 'evaluate' when hovering over source
        response.body.supportsEvaluateForHovers = true;

        // Make VS Code show a 'step back' button
        response.body.supportsStepBack = false;

        // Make VS Code support data breakpoints
        response.body.supportsDataBreakpoints = false;

        // Make VS Code support completion in REPL
        response.body.supportsCompletionsRequest = true;
        response.body.completionTriggerCharacters = [".", "["];

        // Make VS Code send cancelRequests
        response.body.supportsCancelRequest = true;

        // Make VS Code send the breakpointLocations request
        response.body.supportsBreakpointLocationsRequest = true;

        // Make VS Code provide "Step in Target" functionality
        response.body.supportsStepInTargetsRequest = false;

        // The adapter defines two exceptions filters, one with support for conditions
        response.body.supportsExceptionFilterOptions = true;
        response.body.exceptionBreakpointFilters = [
            {
                filter: 'all',
                label: 'All Exceptions',
                description: 'Break on all exceptions',
                default: false
            },
            {
                filter: 'uncaught',
                label: 'Uncaught Exceptions',
                description: 'Break on uncaught exceptions',
                default: true
            }
        ];

        // Make VS Code send exceptionInfoRequests
        response.body.supportsExceptionInfoRequest = true;

        // Make VS Code send setVariable requests
        response.body.supportsSetVariable = true;

        // Make VS Code send setExpression requests
        response.body.supportsSetExpression = false;

        // Make VS Code send disassemble requests
        response.body.supportsDisassembleRequest = false;
        response.body.supportsSteppingGranularity = false;
        response.body.supportsInstructionBreakpoints = false;

        // Make VS Code able to read and write variable memory
        response.body.supportsReadMemoryRequest = false;
        response.body.supportsWriteMemoryRequest = false;

        this.sendResponse(response);

        // Since this debug adapter can accept configuration requests like 'setBreakpoint' at any time,
        // we request them early by sending an 'initializeRequest' to the frontend.
        // The frontend will end the configuration sequence by calling 'configurationDone' request.
        this.sendEvent(new InitializedEvent());
    }

    protected configurationDoneRequest(
        response: DebugProtocol.ConfigurationDoneResponse,
        args: DebugProtocol.ConfigurationDoneArguments
    ): void {
        super.configurationDoneRequest(response, args);
    }

    protected async launchRequest(
        response: DebugProtocol.LaunchResponse,
        args: LaunchRequestArguments
    ): Promise<void> {
        // Make sure the program exists
        if (!fs.existsSync(args.program)) {
            this.sendErrorResponse(
                response,
                2001,
                `Program '${args.program}' does not exist.`
            );
            return;
        }

        // Enable profiler if requested
        this._profilerEnabled = args.profiler || false;
        if (this._profilerEnabled) {
            this.sendEvent(new OutputEvent('Profiler enabled\n', 'console'));
        }

        // Start the Home process
        const cwd = args.cwd || path.dirname(args.program);
        const ionArgs = ['debug', args.program, ...(args.args || [])];

        this._ionProcess = spawn('ion', ionArgs, {
            cwd,
            stdio: ['ignore', 'pipe', 'pipe']
        });

        this._ionProcess.stdout?.on('data', (data) => {
            const output = data.toString();

            // Parse debug messages from Home runtime
            this.parseDebugOutput(output);

            // Send regular output to console
            const lines = output.split('\n');
            for (const line of lines) {
                if (!line.startsWith('[DEBUG]')) {
                    this.sendEvent(new OutputEvent(line + '\n', 'stdout'));
                }
            }

            if (this._profilerEnabled) {
                this.collectProfilerData(output);
            }
        });

        this._ionProcess.stderr?.on('data', (data) => {
            this.sendEvent(new OutputEvent(data.toString(), 'stderr'));
        });

        this._ionProcess.on('exit', (code) => {
            this.sendEvent(new OutputEvent(`Process exited with code ${code}\n`, 'console'));
            if (this._profilerEnabled) {
                this.saveProfilerReport();
            }
            this.sendEvent(new TerminatedEvent());
        });

        // Stop on entry if requested
        if (args.stopOnEntry) {
            this.sendEvent(new StoppedEvent('entry', HomeDebugSession.THREAD_ID));
        } else {
            this.sendEvent(new StoppedEvent('breakpoint', HomeDebugSession.THREAD_ID));
        }

        this.sendResponse(response);
    }

    protected async attachRequest(
        response: DebugProtocol.AttachResponse,
        args: AttachRequestArguments
    ): Promise<void> {
        // Attach to an existing Home process
        this.sendEvent(new OutputEvent(`Attaching to process ${args.processId}\n`, 'console'));

        // TODO: Implement process attachment logic

        this.sendResponse(response);
    }

    protected setBreakPointsRequest(
        response: DebugProtocol.SetBreakpointsResponse,
        args: DebugProtocol.SetBreakpointsArguments
    ): void {
        const path = args.source.path as string;
        const clientLines = args.lines || [];

        // Clear all breakpoints for this file
        this._breakpoints.delete(path);

        // Set and verify breakpoint locations
        const actualBreakpoints = clientLines.map(line => {
            const bp = new Breakpoint(true, line) as DebugProtocol.Breakpoint;
            bp.verified = true;
            return bp;
        });

        this._breakpoints.set(path, actualBreakpoints);

        // Send back the actual breakpoint positions
        response.body = {
            breakpoints: actualBreakpoints
        };
        this.sendResponse(response);
    }

    protected breakpointLocationsRequest(
        response: DebugProtocol.BreakpointLocationsResponse,
        args: DebugProtocol.BreakpointLocationsArguments
    ): void {
        if (args.source.path) {
            response.body = {
                breakpoints: [
                    {
                        line: args.line,
                        column: args.column
                    }
                ]
            };
        } else {
            response.body = {
                breakpoints: []
            };
        }
        this.sendResponse(response);
    }

    protected threadsRequest(response: DebugProtocol.ThreadsResponse): void {
        // Return a single thread
        response.body = {
            threads: [
                new Thread(HomeDebugSession.THREAD_ID, "Main Thread")
            ]
        };
        this.sendResponse(response);
    }

    protected stackTraceRequest(
        response: DebugProtocol.StackTraceResponse,
        args: DebugProtocol.StackTraceArguments
    ): void {
        const startFrame = typeof args.startFrame === 'number' ? args.startFrame : 0;
        const maxLevels = typeof args.levels === 'number' ? args.levels : 1000;

        // Get real stack frames from debugger state
        const allFrames = this._debuggerState.stackFrames;
        const frames: StackFrame[] = [];

        const endFrame = Math.min(startFrame + maxLevels, allFrames.length);
        for (let i = startFrame; i < endFrame; i++) {
            const frameData = allFrames[i];
            const frame = new StackFrame(
                frameData.id,
                frameData.name,
                new Source(path.basename(frameData.file), frameData.file),
                frameData.line,
                frameData.column
            );
            frames.push(frame);
        }

        // If no frames from debugger, show at least current location
        if (frames.length === 0 && this._debuggerState.currentFile) {
            frames.push(new StackFrame(
                0,
                'main',
                new Source(
                    path.basename(this._debuggerState.currentFile),
                    this._debuggerState.currentFile
                ),
                this._debuggerState.currentLine || 1,
                0
            ));
        }

        response.body = {
            stackFrames: frames,
            totalFrames: allFrames.length || frames.length
        };
        this.sendResponse(response);
    }

    protected scopesRequest(
        response: DebugProtocol.ScopesResponse,
        args: DebugProtocol.ScopesArguments
    ): void {
        const frameId = args.frameId;
        const scopes: DebugProtocol.Scope[] = [];

        // Create scope handles for this frame
        const localScopeHandle = this._scopeHandles.create(frameId);
        const globalScopeHandle = this._scopeHandles.create(-1); // -1 for global

        scopes.push(new Scope("Local", localScopeHandle, false));
        scopes.push(new Scope("Global", globalScopeHandle, true));

        response.body = { scopes };
        this.sendResponse(response);
    }

    protected variablesRequest(
        response: DebugProtocol.VariablesResponse,
        args: DebugProtocol.VariablesArguments
    ): void {
        let variables: DebugProtocol.Variable[] = [];

        // Check if this is a scope handle or variable handle
        const scopeFrameId = this._scopeHandles.get(args.variablesReference);

        if (scopeFrameId !== undefined) {
            // This is a scope request - get variables for this frame
            const frameVars = this._debuggerState.variables.get(scopeFrameId);
            if (frameVars) {
                variables = frameVars.map(v => ({
                    name: v.name,
                    type: v.type,
                    value: v.value,
                    variablesReference: v.variablesReference
                }));
            }
        } else {
            // This is a structured variable request
            const varData = this._variableHandles.get(args.variablesReference);
            if (varData) {
                variables = varData.map(v => ({
                    name: v.name,
                    type: v.type,
                    value: v.value,
                    variablesReference: v.variablesReference
                }));
            }
        }

        response.body = { variables };
        this.sendResponse(response);
    }

    protected continueRequest(
        response: DebugProtocol.ContinueResponse,
        args: DebugProtocol.ContinueArguments
    ): void {
        this.sendResponse(response);
    }

    protected nextRequest(
        response: DebugProtocol.NextResponse,
        args: DebugProtocol.NextArguments
    ): void {
        this.sendEvent(new StoppedEvent('step', HomeDebugSession.THREAD_ID));
        this.sendResponse(response);
    }

    protected stepInRequest(
        response: DebugProtocol.StepInResponse,
        args: DebugProtocol.StepInArguments
    ): void {
        this.sendEvent(new StoppedEvent('step', HomeDebugSession.THREAD_ID));
        this.sendResponse(response);
    }

    protected stepOutRequest(
        response: DebugProtocol.StepOutResponse,
        args: DebugProtocol.StepOutArguments
    ): void {
        this.sendEvent(new StoppedEvent('step', HomeDebugSession.THREAD_ID));
        this.sendResponse(response);
    }

    protected evaluateRequest(
        response: DebugProtocol.EvaluateResponse,
        args: DebugProtocol.EvaluateArguments
    ): void {
        // Evaluate an expression
        response.body = {
            result: `Evaluated: ${args.expression}`,
            variablesReference: 0
        };
        this.sendResponse(response);
    }

    protected setVariableRequest(
        response: DebugProtocol.SetVariableResponse,
        args: DebugProtocol.SetVariableArguments
    ): void {
        // Set a variable value
        response.body = {
            value: args.value,
            type: 'string',
            variablesReference: 0
        };
        this.sendResponse(response);
    }

    protected disconnectRequest(
        response: DebugProtocol.DisconnectResponse,
        args: DebugProtocol.DisconnectArguments
    ): void {
        if (this._ionProcess) {
            this._ionProcess.kill();
        }

        if (this._profilerEnabled) {
            this.saveProfilerReport();
        }

        this.sendResponse(response);
    }

    private collectProfilerData(output: string) {
        // Collect profiler data from debug output
        const lines = output.split('\n');
        for (const line of lines) {
            if (line.startsWith('[PROFILE]')) {
                try {
                    const data = JSON.parse(line.substring(9));
                    this._profilerData.push(data);
                } catch (e) {
                    // Ignore malformed profiler data
                }
            }
        }
    }

    private saveProfilerReport() {
        if (this._profilerData.length === 0) {
            return;
        }

        const report = {
            timestamp: new Date().toISOString(),
            data: this._profilerData
        };

        const reportPath = path.join(process.cwd(), 'ion-profile.json');
        fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

        this.sendEvent(new OutputEvent(`Profiler report saved to ${reportPath}\n`, 'console'));
    }

    /**
     * Parse debug output from Home runtime
     *
     * Expected format from Zig debugger:
     * [DEBUG] Breakpoint hit at file.home:42
     * [DEBUG] STACK: {"frames":[...]}
     * [DEBUG] VARS: {"frameId":0,"variables":[...]}
     */
    private parseDebugOutput(output: string) {
        this._debugOutputBuffer += output;

        const lines = this._debugOutputBuffer.split('\n');
        this._debugOutputBuffer = lines.pop() || ''; // Keep incomplete line in buffer

        for (const line of lines) {
            if (!line.startsWith('[DEBUG]')) continue;

            const debugMsg = line.substring(7).trim();

            // Parse breakpoint hit
            if (debugMsg.startsWith('Breakpoint hit at')) {
                const match = debugMsg.match(/Breakpoint hit at (.+):(\d+)/);
                if (match) {
                    this._debuggerState.currentFile = match[1];
                    this._debuggerState.currentLine = parseInt(match[2], 10);
                    this.sendEvent(new StoppedEvent('breakpoint', HomeDebugSession.THREAD_ID));
                }
            }
            // Parse stack trace
            else if (debugMsg.startsWith('STACK:')) {
                try {
                    const jsonData = debugMsg.substring(6).trim();
                    const stackData = JSON.parse(jsonData);
                    this._debuggerState.stackFrames = stackData.frames.map((f: any, idx: number) => ({
                        id: idx,
                        name: f.name || 'anonymous',
                        file: f.file || '',
                        line: f.line || 0,
                        column: f.column || 0,
                        environmentId: f.environmentId || idx
                    }));
                } catch (e) {
                    this.sendEvent(new OutputEvent(`Failed to parse stack trace: ${e}\n`, 'stderr'));
                }
            }
            // Parse variables
            else if (debugMsg.startsWith('VARS:')) {
                try {
                    const jsonData = debugMsg.substring(5).trim();
                    const varsData = JSON.parse(jsonData);
                    const frameId = varsData.frameId || 0;

                    const variables: VariableData[] = varsData.variables.map((v: any) => ({
                        name: v.name,
                        value: this.formatValue(v.value, v.type),
                        type: v.type || 'unknown',
                        variablesReference: this.createVariableReference(v.value, v.type)
                    }));

                    this._debuggerState.variables.set(frameId, variables);
                } catch (e) {
                    this.sendEvent(new OutputEvent(`Failed to parse variables: ${e}\n`, 'stderr'));
                }
            }
            // Parse step completed
            else if (debugMsg.startsWith('Step completed')) {
                this.sendEvent(new StoppedEvent('step', HomeDebugSession.THREAD_ID));
            }
            // Parse program entry
            else if (debugMsg.startsWith('Stopped on entry')) {
                this.sendEvent(new StoppedEvent('entry', HomeDebugSession.THREAD_ID));
            }
            // Parse exceptions
            else if (debugMsg.startsWith('Exception:')) {
                const exceptionMsg = debugMsg.substring(10).trim();
                this.sendEvent(new OutputEvent(`Exception: ${exceptionMsg}\n`, 'stderr'));
                this.sendEvent(new StoppedEvent('exception', HomeDebugSession.THREAD_ID));
            }
        }
    }

    /**
     * Format a value for display
     */
    private formatValue(value: any, type: string): string {
        if (value === null || value === undefined) {
            return 'void';
        }

        switch (type) {
            case 'Int':
                return value.toString();
            case 'Float':
                return value.toFixed(2);
            case 'Bool':
                return value ? 'true' : 'false';
            case 'String':
                return `"${value}"`;
            case 'Array':
                if (Array.isArray(value)) {
                    return `[${value.length} elements]`;
                }
                return '[Array]';
            case 'Struct':
                return `{${Object.keys(value || {}).join(', ')}}`;
            case 'Function':
                return `<function>`;
            default:
                return String(value);
        }
    }

    /**
     * Create variable reference for structured types
     */
    private createVariableReference(value: any, type: string): number {
        if (type === 'Array' && Array.isArray(value)) {
            const children: VariableData[] = value.map((v, idx) => ({
                name: `[${idx}]`,
                value: this.formatValue(v.value, v.type),
                type: v.type || 'unknown',
                variablesReference: 0
            }));
            return this._variableHandles.create(children);
        } else if (type === 'Struct' && typeof value === 'object') {
            const children: VariableData[] = Object.entries(value).map(([key, v]: [string, any]) => ({
                name: key,
                value: this.formatValue(v.value, v.type),
                type: v.type || 'unknown',
                variablesReference: 0
            }));
            return this._variableHandles.create(children);
        }
        return 0;
    }
}

// Start the debug adapter
HomeDebugSession.run(HomeDebugSession);
