import type { WindowOptions } from 'craft-core'
import { TileLayer } from 'map-dist'

export function mapWindow(title: string) {
  const options: WindowOptions = { title, width: 1024 }
  return options
}

export function addTiles(container: HTMLElement): TileLayer {
  const layer = new TileLayer('https://tiles.example/{z}/{x}/{y}.png')
  layer.attach(container)
  return layer
}
