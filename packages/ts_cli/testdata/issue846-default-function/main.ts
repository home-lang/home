import addOne from './bridge.js'

const good: number = addOne(1)
const wrongReturn: string = addOne(1)
addOne('bad')
void [good, wrongReturn]
