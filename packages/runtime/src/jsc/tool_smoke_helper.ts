export function expectedEngineMarker(engine: "zig-js" | "jsc"): string {
  return `engine=${engine}`;
}
