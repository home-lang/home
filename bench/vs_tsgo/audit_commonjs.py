#!/usr/bin/env python3
"""Untimed cross-file CommonJS instance consumption controls for #536."""

from audit_globals import Case, audit


def cases() -> list[Case]:
    base = "class Service { value = 'text'; }\n"
    variants = {
        "direct": base + "module.exports = new Service();\n",
        "bracket": base + "module['exports'] = new Service();\n",
        "parentheses": base + "module.exports = (new Service());\n",
        "comment": base + "// module.exports = new Fake();\nmodule.exports = new Service();\n",
        "comment-only": base + "// module.exports = new Fake();\nmodule.exports = { value: 1 };\n",
        "string-only": base + "const note = 'module.exports = new Fake()';\nmodule.exports = { value: 1 };\n",
        "reassigned": base + "class Other { value = 1; }\nmodule.exports = new Service();\nmodule.exports = new Other();\n",
        "same-class": base + "module.exports = new Service();\nmodule.exports = new Service();\n",
        "shadowed": base + "function local() { const module = { exports: {} }; module.exports = new Service(); }\nmodule.exports = { value: 1 };\n",
        "nested": base + "function later() { module.exports = new Service(); }\nmodule.exports = { value: 1 };\n",
        "alias": base + "const Alias = Service;\nmodule.exports = new Alias();\n",
    }
    positive = "const instance = require('./owner');\n/** @type {string | number} */ const good = instance.value;\n"
    controls = (
        ("positive", positive, ()),
        ("wrong-type", positive + "/** @type {boolean} */ const bad = instance.value;\n", ("2322",)),
        ("missing", positive + "instance.missing;\n", ("2339",)),
    )
    return [
        Case(f"app-{order}/{control}", family, {"owner.js": owner, app: source}, expected, check_js=True)
        for family, owner in variants.items()
        for order, app in (("before", "0-app.js"), ("after", "z-app.js"))
        for control, source, expected in controls
    ]


if __name__ == "__main__":
    raise SystemExit(audit(cases()))
