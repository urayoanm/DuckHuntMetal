# DuckHuntMetal

A complete, single-file SwiftUI implementation of a Duck Hunt–style shooting game for iOS 17+.

## Features

- **Multiple duck types** – Normal (100 pts), Fast (200 pts), Zigzag (150 pts), Boss (300 pts, 3 hits), Decoy (0 pts)
- **Power-ups** – +1 Ammo, ×2 Score, Slow-Motion; float onto screen mid-round
- **Dog companion** – pops up to fetch downed ducks or laugh at misses
- **Particle effects** – feather bursts, score popups, laugh bubbles, muzzle flash
- **Retro CRT look** – scanline overlay, radial vignette
- **Crosshair** – shows at last tap location
- **Haptic feedback** – heavy impact on shot, success notification on hit
- **Endless rounds** – difficulty increases (more ducks, higher speed) each round
- **High-score tracking** within the session

## How to Run

1. Open `DuckHuntMetal.xcodeproj` in Xcode 15+  
2. Select an iPhone or iPad simulator (iOS 17+)  
3. Build & Run (`⌘R`)

### Single-file paste

All game logic is contained in `DuckHuntMetal/DuckHuntGame.swift`.  
You can paste it into any Xcode SwiftUI App project (iOS 17 target) alongside the generated `*App.swift` entry point and it will work immediately.

## Controls

| Action | Gesture |
|--------|---------|
| Start game | Tap anywhere on the title screen |
| Shoot | Tap anywhere during a round |
| Collect power-up | Tap the floating icon |

## Architecture

```
GameModel (ObservableObject)
  ├── [Duck]        – position, velocity, type, health, animation state
  ├── [PowerUp]     – position, type, lifetime
  ├── [Particle]    – hit sparks, feathers, text popups
  └── dog state, score, ammo, round, timers

DuckHuntGameView
  ├── GeometryReader  – provides screen size to GameModel
  ├── TimelineView    – drives 60 fps game loop via .onChange
  ├── Canvas          – draws entire scene (background, ducks, dog, particles, HUD effects)
  ├── HUDView         – SwiftUI overlay for score / round / ammo / power-up indicators
  └── StartScreenView – title / instructions overlay
```
