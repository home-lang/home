export function render(request, metadata) {
  return metadata.pageModule.default(request, metadata);
}

export function registerClientReference(value, file, uid) {
  return { value, file, uid };
}
