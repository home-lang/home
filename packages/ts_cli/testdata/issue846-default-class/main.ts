import Box from './bridge.js'

const box = new Box()
const count: number = box.count
const wrongRead: string = box.count
box.count = 'bad'
box.set('bad')

void [count, wrongRead]
