import settings from './bridge.js'
import * as bridge from './bridge.js'

const count: number = settings.count
const label: string = bridge.default.label
const wrongRead: string = settings.count
settings.count = 'bad'
const wrongNamespaceRead: number = bridge.default.label
bridge.default.label = 42

void [count, label, wrongRead, wrongNamespaceRead]
