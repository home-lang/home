export default function (_request, metadata) {
  return new globalThis.Response(`HOME_BAKE_FRAMEWORK_SLUG:${metadata.params.slug}`);
}
