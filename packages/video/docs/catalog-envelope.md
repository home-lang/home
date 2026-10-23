# Exact nested catalog snapshots

`catalog_envelope` appends and extracts an entire HCAT catalog as one named,
read-only byte-array record in another HCAT catalog. Inner headers, record order,
identities, vendor strings, native types, flags, value byte order, labels and opaque
payloads stay byte-for-byte intact. No camera or backend schema is assumed.

`Spec` selects an exact group/id/name/vendor identity, expected inner catalog kind
and maximum nested byte count. `append(writer, spec, inner)` validates both catalogs
and refuses an existing reserved identity. Source/identity aliasing of allocated
writer storage is rejected before growth. Capacity is reserved before mutation;
allocation, bounds or shape failure leaves valid writer contents/count unchanged.

`find(outer, expected_outer_kind, spec)` returns a borrowed payload, or null for
legacy absence. A matching group/id/vendor with a different name or shape is an
error. Duplicate identities reject. The complete outer catalog, including foreign
tails, is validated before returning a candidate. The sole current byte-array
value must have exact flags, extent/count, role, native type and label; its nested
HCAT and kind are validated as well.

`copy(outer, outer_kind, spec, output)` returns the copied nested byte count.
Missing/ambiguous/malformed input, short output and source/output or identity/
output overlap reject before a prefix write. Extra destination suffix remains
unchanged. Callers retain immutable inputs during calls and own returned copies;
borrowed `find` results do not extend source lifetime.

The helper bounds nested bytes with `Spec.max_bytes`; callers bound total input
and writer storage separately. `find` and `copy` allocate nothing and perform no
I/O. Identity matching is a schema/provenance selector, not authentication. A
transport/owner must separately validate peers, lifetime, admission and access.

Focused tests cover exact opaque preservation, independent copies, missing and
foreign identities, duplicate rejection, wrong kinds/flags/roles/extents/native
types, nested and foreign-tail corruption, byte limits, overlap, unchanged output
suffixes and atomic writer state under every allocation failure. The consumer
can expose a source snapshot without rebasing vendor identities into another
namespace or adding a descriptor channel to its existing metadata transport.
