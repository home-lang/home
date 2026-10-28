import settings from './owner.js'

const wrongRead: string = settings.count
settings.count = 'bad'

void wrongRead
