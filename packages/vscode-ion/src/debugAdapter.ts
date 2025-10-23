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

export class IonDebugSession extends LoggingDebugSession {
    private static THREAD_ID = 1;

    private _variableHandles = new Handles<string>();
    private _ionProcess: ChildProcess | undefined;
    private _breakpoints = new Map<string, DebugProtocol.Breakpoint[]>();
    private _profilerEnabled = false;
    private _profilerData: any[] = [];

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

        // Start the Ion process
        const cwd = args.cwd || path.dirname(args.program);
        const ionArgs = ['debug', args.program, ...(args.args || [])];

        this._ionProcess = spawn('ion', ionArgs, {
            cwd,
            stdio: ['ignore', 'pipe', 'pipe']
        });

        this._ionProcess.stdout?.on('data', (data) => {
            this.sendEvent(new OutputEvent(data.toString(), 'stdout'));
            if (this._profilerEnabled) {
                this.collectProfilerData(data.toString());
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
            this.sendEvent(new StoppedEvent('entry', IonDebugSession.THREAD_ID));
        } else {
            this.sendEvent(new StoppedEvent('breakpoint', IonDebugSession.THREAD_ID));
        }

        this.sendResponse(response);
    }

    protected async attachRequest(
        response: DebugProtocol.AttachResponse,
        args: AttachRequestArguments
    ): Promise<void> {
        // Attach to an existing Ion process
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
                new Thread(IonDebugSession.THREAD_ID, "Main Thread")
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

        // Return a dummy stack frame for now
        const frames: StackFrame[] = [
            new StackFrame(
                0,
                'main',
                new Source('main.ion', 'main.ion'),
                1,
                0
            )
        ];

        response.body = {
            stackFrames: frames,
            totalFrames: frames.length
        };
        this.sendResponse(response);
    }

    protected scopesRequest(
        response: DebugProtocol.ScopesResponse,
        args: DebugProtocol.ScopesArguments
    ): void {
        response.body = {
            scopes: [
                new Scope("Local", this._variableHandles.create("local"), false),
                new Scope("Global", this._variableHandles.create("global"), true)
            ]
        };
        this.sendResponse(response);
    }

    protected variablesRequest(
        response: DebugProtocol.VariablesResponse,
        args: DebugProtocol.VariablesArguments
    ): void {
        const variables: DebugProtocol.Variable[] = [];
        const id = this._variableHandles.get(args.variablesReference);

        if (id === 'local') {
            // Return local variables
            variables.push({
                name: 'i',
                type: 'integer',
                value: '42',
                variablesReference: 0
            });
        } else if (id === 'global') {
            // Return global variables
            variables.push({
                name: 'version',
                type: 'string',
                value: '"1.0.0"',
                variablesReference: 0
            });
        }

        response.body = {
            variables: variables
        };
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
        this.sendEvent(new StoppedEvent('step', IonDebugSession.THREAD_ID));
        this.sendResponse(response);
    }

    protected stepInRequest(
        response: DebugProtocol.StepInResponse,
        args: DebugProtocol.StepInArguments
    ): void {
        this.sendEvent(new StoppedEvent('step', IonDebugSession.THREAD_ID));
        this.sendResponse(response);
    }

    protected stepOutRequest(
        response: DebugProtocol.StepOutResponse,
        args: DebugProtocol.StepOutArguments
    ): void {
        this.sendEvent(new StoppedEvent('step', IonDebugSession.THREAD_ID));
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
}

// Start the debug adapter
IonDebugSession.run(IonDebugSession);
