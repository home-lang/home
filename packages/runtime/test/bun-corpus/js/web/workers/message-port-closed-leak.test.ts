import { describe, expect, test } from "bun:test";
import { bunEnv, bunExe, isASAN } from "harness";

// https://github.com/home-lang/home/issues/466: close() has a pending receive
// window. Measure completed closure, not messages legitimately retained until
// its asynchronous close event. Resolve without Event payloads so these waits
// do not themselves retain the closed targets across GC.
const closeHelpers = `
  function closed(port) {
    return new Promise(resolve => port.addEventListener("close", () => resolve(), { once: true }));
  }
  async function waitForCloses(promises) {
    let timer;
    try {
      await Promise.race([
        Promise.all(promises),
        new Promise((resolve, reject) => {
          timer = setTimeout(() => reject(new Error("MessagePort close completion timed out")), 10_000);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }
`;

// https://bugs.webkit.org/show_bug.cgi?id=281662
// Transferring buffers to a closed MessageChannel causes memory leaks
describe("MessagePortChannel closed port", () => {
  test("postMessage to closed port does not accumulate in pending queue", async () => {
    await using proc = Bun.spawn({
      cmd: [
        bunExe(),
        "-e",
        `
          ${closeHelpers}
          const { port1, port2 } = new MessageChannel();
          const senderClosed = closed(port1);
          const receiverClosed = closed(port2);
          // Keep the unstarted sender open to exercise the closed destination,
          // rather than the separate already-closed sender no-op path.
          port2.postMessage("keep sender open");
          port2.close();
          await waitForCloses([receiverClosed]);

          // Warm up: first batch establishes allocator high-water mark
          for (let i = 0; i < 5000; i++) {
            port1.postMessage(Buffer.alloc(64 * 1024).toString());
          }
          Bun.gc(true);
          Bun.gc(true);

          // Measure: second batch should reuse freed memory if messages
          // are dropped (not queued) for closed ports.
          const rssBefore = process.memoryUsage().rss;
          for (let i = 0; i < 5000; i++) {
            port1.postMessage(Buffer.alloc(64 * 1024).toString());
          }
          Bun.gc(true);
          Bun.gc(true);
          const rssAfter = process.memoryUsage().rss;
          const deltaMB = (rssAfter - rssBefore) / 1024 / 1024;

          // Without fix: ~300+ MB growth (5000 * 64KB queued)
          // With fix: ~0-5 MB (allocator reuses freed memory)
          // ASAN's quarantine retains freed allocations so widen the threshold there.
          if (deltaMB > ${isASAN ? 256 : 50}) {
            console.error("FAIL: RSS grew by", deltaMB.toFixed(2), "MB on second batch");
            process.exit(1);
          }
          port1.close();
          await waitForCloses([senderClosed]);
          console.log("PASS: delta", deltaMB.toFixed(2), "MB");
        `,
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);

    expect(stderr).toBe("");
    expect(stdout).toContain("PASS");
    expect(exitCode).toBe(0);
  }, 60_000);

  // A MessagePort transferred via postMessage(_, [port]) that is never received on the other
  // side (because the carrying message is dropped) must not leak its pipe. Cleanup relies on
  // ~TransferredMessagePort calling pipe->close(side) when the carrying message is destroyed.
  for (const closeBeforePost of [false, true]) {
    test(`transferred port dropped ${closeBeforePost ? "after" : "before"} receiver closed does not leak channel`, async () => {
      await using proc = Bun.spawn({
        cmd: [
          bunExe(),
          "-e",
          `
            ${closeHelpers}
            const closeBeforePost = ${closeBeforePost};
            const ITERATIONS = 1000;
            const PAYLOAD_SIZE = 128 * 1024;

            async function round() {
              const pendingCloses = [];
              for (let i = 0; i < ITERATIONS; i++) {
                const carrier = new MessageChannel();
                const inner = new MessageChannel();
                const receiverClosed = closed(carrier.port2);
                pendingCloses.push(closed(carrier.port1), receiverClosed, closed(inner.port1), closed(inner.port2));

                // Queue a large payload on the side of the inner channel that is about
                // to be transferred. If the inner channel leaks, this payload leaks with it.
                inner.port2.postMessage(Buffer.alloc(PAYLOAD_SIZE).toString());

                if (closeBeforePost) {
                  // Keep the unstarted sender open while its peer finishes closing.
                  carrier.port2.postMessage("keep sender open");
                  carrier.port2.close();
                  await waitForCloses([receiverClosed]);
                  // Drop path: send() sees completed closure on the destination
                  // side and returns; the moved-in message destructs and
                  // ~TransferredMessagePort closes the inner pipe side.
                  carrier.port1.postMessage(null, [inner.port1]);
                } else {
                  // Drop path: close completion swaps out the inbox; the dropped
                  // TransferredMessagePort is harvested into the close worklist.
                  carrier.port1.postMessage(null, [inner.port1]);
                  carrier.port2.close();
                }

                inner.port2.close();
                carrier.port1.close();
              }
              await waitForCloses(pendingCloses);
              pendingCloses.length = 0;
              Bun.gc(true);
              Bun.gc(true);
            }

            // Warm up to establish allocator high-water mark.
            await round();

            const rssBefore = process.memoryUsage().rss;
            await round();
            const rssAfter = process.memoryUsage().rss;
            const deltaMB = (rssAfter - rssBefore) / 1024 / 1024;

            // Without fix: ~130+ MB growth (1000 leaked channels each holding a 128KB string).
            // With fix: ~0-10 MB.
            // ASAN's quarantine retains freed allocations so widen the threshold there.
            if (deltaMB > ${isASAN ? 256 : 60}) {
              console.error("FAIL: RSS grew by", deltaMB.toFixed(2), "MB on second batch");
              process.exit(1);
            }
            console.log("PASS: delta", deltaMB.toFixed(2), "MB");
          `,
        ],
        env: bunEnv,
        stdout: "pipe",
        stderr: "pipe",
      });

      const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);

      expect(stderr).toBe("");
      expect(stdout).toContain("PASS");
      expect(exitCode).toBe(0);
    }, 60_000);
  }

  // Closing a port whose inbox holds a transferred port whose inbox holds a transferred
  // port whose... must not overflow the native stack. ~TransferredMessagePort calls
  // pipe->close(), which drops the inbox, whose destruction calls ~TransferredMessagePort
  // again; MessagePortPipe::close() must drain that cascade iteratively.
  test("deep chain of nested transferred ports does not overflow on close", async () => {
    await using proc = Bun.spawn({
      cmd: [
        bunExe(),
        "-e",
        `
          ${closeHelpers}
          const DEPTH = 20_000;
          let head = new MessageChannel();
          const tail = head;
          const pendingCloses = [closed(head.port1), closed(head.port2)];
          let cascadeClosed;
          for (let i = 0; i < DEPTH; i++) {
            const next = new MessageChannel();
            cascadeClosed = closed(next.port2);
            pendingCloses.push(closed(next.port1), cascadeClosed);
            // head.port1's inbox now holds next.port1; closing head.port1 must
            // cascade to next.port1, whose inbox holds the following link, etc.
            head.port2.postMessage(null, [next.port1]);
            head.port2.close();
            head = next;
          }
          tail.port1.close();
          // Only the completed orphan cascade can close this final peer.
          await waitForCloses([cascadeClosed]);
          head.port2.close();
          await waitForCloses(pendingCloses);
          console.log("PASS");
        `,
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);

    // Without the iterative drain the subprocess segfaults (stack overflow) during
    // completion of tail.port1.close() and never prints PASS.
    expect({ stdout: stdout.trim(), exitCode, signalCode: proc.signalCode, stderr }).toEqual({
      stdout: "PASS",
      exitCode: 0,
      signalCode: null,
      stderr: "",
    });
  }, 60_000);
});
