// DuckHuntGame.swift
// Complete Duck Hunt Metal – SwiftUI iOS 17+ single-file implementation
//
// Architecture:
//   • GameModel  – ObservableObject holding all game state (ducks, powerups, particles, dog, score, etc.)
//   • DuckHuntGameView – root view: GeometryReader + ZStack(Canvas + HUD)
//   • Game loop via TimelineView(.animation) + .onChange(of: timeline.date)
//   • Pure SwiftUI Canvas for all drawing – no SpriteKit, no UIKit

import SwiftUI
import UIKit   // for UIImpactFeedbackGenerator / UINotificationFeedbackGenerator

// MARK: - Duck

enum DuckType: Equatable {
    case normal   // 100 pts – standard white duck
    case fast     // 200 pts – small red, very fast
    case zigzag   // 150 pts – teal, changes horizontal direction
    case boss     // 300 pts – large purple, 3 hits required
    case decoy    // 0 pts   – golden, wastes a shot
}

enum DuckState {
    case flying, hit, falling, dead, escaped
}

struct Duck: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
    var type: DuckType
    var state: DuckState = .flying
    var health: Int
    var rotation: Double = 0          // degrees
    var fallVelocity: Double = 0
    var sineOffset: Double = Double.random(in: 0 ..< .pi * 2)
    var time: Double = 0
    var wingPhase: Double = Double.random(in: 0 ..< .pi * 2)
    var zigzagTimer: Double = Double.random(in: 0.6 ... 1.4)

    var size: CGSize {
        switch type {
        case .normal: return CGSize(width: 52, height: 42)
        case .fast:   return CGSize(width: 34, height: 26)
        case .zigzag: return CGSize(width: 46, height: 36)
        case .boss:   return CGSize(width: 72, height: 58)
        case .decoy:  return CGSize(width: 48, height: 38)
        }
    }

    var points: Int {
        switch type {
        case .normal: return 100
        case .fast:   return 200
        case .zigzag: return 150
        case .boss:   return 300
        case .decoy:  return 0
        }
    }

    var bodyColor: Color {
        switch type {
        case .normal: return Color(red: 0.95, green: 0.95, blue: 0.95)
        case .fast:   return Color(red: 0.82, green: 0.18, blue: 0.18)
        case .zigzag: return Color(red: 0.12, green: 0.72, blue: 0.80)
        case .boss:   return Color(red: 0.52, green: 0.20, blue: 0.72)
        case .decoy:  return Color(red: 0.78, green: 0.72, blue: 0.18)
        }
    }

    /// Expanded bounding rectangle used for hit-testing (slightly larger than visual size).
    var hitRect: CGRect {
        CGRect(
            x: position.x - size.width / 2 - 8,
            y: position.y - size.height / 2 - 8,
            width: size.width + 16,
            height: size.height + 16
        )
    }

    mutating func takeHit() -> Bool {
        health -= 1
        if health <= 0 {
            state = .hit
            return true
        }
        return false
    }
}

// MARK: - Power-up

enum PowerUpType: CaseIterable {
    case extraAmmo    // +1 ammo bullet
    case doubleScore  // ×2 score for 10 s
    case slowMotion   // slow all ducks for 5 s
}

struct PowerUp: Identifiable {
    let id = UUID()
    var position: CGPoint
    var type: PowerUpType
    var collected = false
    var life: Double = 6.0   // seconds until auto-remove

    var accentColor: Color {
        switch type {
        case .extraAmmo:   return .yellow
        case .doubleScore: return .orange
        case .slowMotion:  return .cyan
        }
    }

    var label: String {
        switch type {
        case .extraAmmo:   return "+1"
        case .doubleScore: return "×2"
        case .slowMotion:  return "⏱"
        }
    }
}

// MARK: - Particle

struct Particle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
    var color: Color
    var size: Double
    var life: Double = 1.0
    var text: String? = nil
}

// MARK: - Game State & Dog

enum RunningState { case start, playing, roundEnd }

enum DogAnimation { case hidden, appearing, visible, disappearing }

// MARK: - Precomputed Grass

struct GrassBlade {
    var x: Double
    var height: Double
    var lean: Double   // horizontal tip offset
}

// MARK: - GameModel

@MainActor
final class GameModel: ObservableObject {

    // ── Published state ──────────────────────────────────────────────────────
    @Published var ducks: [Duck] = []
    @Published var powerUps: [PowerUp] = []
    @Published var particles: [Particle] = []

    @Published var score = 0
    @Published var highScore = 0
    @Published var ammo = 3
    @Published var round = 1
    @Published var runState: RunningState = .start

    @Published var dogAnim: DogAnimation = .hidden
    @Published var dogOffsetY: Double = 120   // positive = below screen edge
    @Published var dogIsFetching = false

    @Published var crosshairPos = CGPoint(x: 200, y: 400)
    @Published var crosshairVisible = false

    @Published var muzzleFlash: CGPoint? = nil
    @Published var doubleScoreActive = false
    @Published var slowMotionActive = false

    // ── Internal timers ──────────────────────────────────────────────────────
    var screenSize: CGSize = .zero
    var grassBlades: [GrassBlade] = []

    private var roundEndTimer = 0.0
    private var doubleScoreTimer = 0.0
    private var slowMotionTimer = 0.0
    private var muzzleFlashTimer = 0.0
    private var powerUpSpawnTimer = 0.0
    private var dogTimer = 0.0
    private var dogVisibleTimer = 0.0

    // ── Game loop ─────────────────────────────────────────────────────────────
    func update(dt: Double) {
        // Cap delta to avoid spiral of death
        let dt = min(dt, 0.05)

        switch runState {
        case .start:
            break

        case .playing:
            updateTimers(dt: dt)
            let speed = slowMotionActive ? 0.35 : 1.0
            updateDucks(dt: dt * speed)
            updatePowerUps(dt: dt)
            updateParticles(dt: dt)
            updateDog(dt: dt)
            powerUpSpawnTimer += dt
            if powerUpSpawnTimer > 9.0 {
                powerUpSpawnTimer = 0
                if Double.random(in: 0...1) < 0.5 { spawnPowerUp() }
            }
            checkRoundEnd()

        case .roundEnd:
            updateParticles(dt: dt)
            updateDog(dt: dt)
            roundEndTimer -= dt
            if roundEndTimer <= 0 { beginNewRound() }
        }
    }

    private func updateTimers(dt: Double) {
        if doubleScoreActive {
            doubleScoreTimer -= dt
            if doubleScoreTimer <= 0 { doubleScoreActive = false }
        }
        if slowMotionActive {
            slowMotionTimer -= dt
            if slowMotionTimer <= 0 { slowMotionActive = false }
        }
        if muzzleFlash != nil {
            muzzleFlashTimer -= dt
            if muzzleFlashTimer <= 0 { muzzleFlash = nil }
        }
    }

    private func updateDucks(dt: Double) {
        for i in ducks.indices {
            updateDuck(i: i, dt: dt)
        }
    }

    private func updateDuck(i: Int, dt: Double) {
        switch ducks[i].state {

        case .flying:
            ducks[i].time += dt
            // Horizontal
            ducks[i].position.x += ducks[i].velocity.dx * dt
            // Sine-wave vertical
            let amp = 25.0 + Double(round) * 4
            ducks[i].position.y += sin(ducks[i].time * 2.8 + ducks[i].sineOffset) * amp * dt
            // Wing flap
            ducks[i].wingPhase += dt * 12
            // Zigzag direction change (only while player still has ammo)
            if ducks[i].type == .zigzag {
                ducks[i].zigzagTimer -= dt
                if ducks[i].zigzagTimer <= 0 {
                    if ammo > 0 {
                        ducks[i].velocity.dx = -ducks[i].velocity.dx
                    }
                    ducks[i].zigzagTimer = Double.random(in: 0.6 ... 1.4)
                }
            }
            // Clamp y so duck stays in upper 65% of screen
            ducks[i].position.y = ducks[i].position.y.clamped(to: 40 ... screenSize.height * 0.65)

            let margin = 80.0
            let escaped = ducks[i].position.x < -margin
                       || ducks[i].position.x > screenSize.width + margin
            if escaped { ducks[i].state = .escaped }

        case .hit:
            ducks[i].state = .falling
            ducks[i].fallVelocity = 0
            ducks[i].velocity = .zero

        case .falling:
            ducks[i].time += dt
            ducks[i].fallVelocity += 900 * dt
            ducks[i].position.y += ducks[i].fallVelocity * dt
            ducks[i].rotation += 280 * dt
            let groundY = screenSize.height * 0.82 - 10
            if ducks[i].position.y >= groundY {
                ducks[i].position.y = groundY
                ducks[i].state = .dead
            }

        default:
            break
        }
    }

    private func updatePowerUps(dt: Double) {
        for i in powerUps.indices.reversed() {
            powerUps[i].life -= dt
            // Bob
            powerUps[i].position.y += sin(powerUps[i].life * 3) * 18 * dt
            if powerUps[i].life <= 0 || powerUps[i].collected {
                powerUps.remove(at: i)
            }
        }
    }

    private func updateParticles(dt: Double) {
        for i in particles.indices.reversed() {
            particles[i].position.x += particles[i].velocity.dx * dt
            particles[i].position.y += particles[i].velocity.dy * dt
            particles[i].velocity.dy += 220 * dt   // gravity
            particles[i].life -= dt * 1.8
            if particles[i].life <= 0 { particles.remove(at: i) }
        }
    }

    private func updateDog(dt: Double) {
        switch dogAnim {
        case .appearing:
            dogOffsetY = max(0, dogOffsetY - 240 * dt)
            if dogOffsetY <= 0 {
                dogAnim = .visible
                dogVisibleTimer = 2.2
            }
        case .visible:
            dogVisibleTimer -= dt
            if dogVisibleTimer <= 0 { dogAnim = .disappearing }
        case .disappearing:
            dogOffsetY = min(120, dogOffsetY + 240 * dt)
            if dogOffsetY >= 120 {
                dogOffsetY = 120
                dogAnim = .hidden
            }
        default:
            break
        }
    }

    private func checkRoundEnd() {
        guard !ducks.isEmpty else { return }
        let active = ducks.filter {
            $0.state == .flying || $0.state == .hit || $0.state == .falling
        }
        // End round when every duck is dead or escaped (no more in-flight)
        if active.isEmpty { endRound() }
    }

    // MARK: - Actions

    func shoot(at point: CGPoint) {
        guard runState == .playing, ammo > 0 else { return }

        ammo -= 1
        crosshairPos = point
        crosshairVisible = true
        muzzleFlash = point
        muzzleFlashTimer = 0.16

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        // Check power-up hit
        for i in powerUps.indices where !powerUps[i].collected {
            if dist(point, powerUps[i].position) < 38 {
                activatePowerUp(index: i)
                break
            }
        }

        // Check duck hit
        var hitSomething = false
        for i in ducks.indices where ducks[i].state == .flying {
            if ducks[i].hitRect.contains(point) {
                let killed = ducks[i].takeHit()
                if killed {
                    let pts = ducks[i].points * (doubleScoreActive ? 2 : 1)
                    score += pts
                    spawnHitParticles(at: ducks[i].position, color: ducks[i].bodyColor)
                    spawnTextParticle(at: ducks[i].position, text: "+\(pts)", color: .yellow)
                    if dogAnim == .hidden { triggerDog(fetching: true) }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    spawnHitParticles(at: ducks[i].position, color: .red)
                }
                hitSomething = true
                break
            }
        }

        // Miss + out of ammo → dog laughs
        if !hitSomething && ammo == 0 {
            let anyAlive = ducks.contains { $0.state == .flying }
            if anyAlive && dogAnim == .hidden { triggerDog(fetching: false) }
        }
    }

    // MARK: - Dog

    private func triggerDog(fetching: Bool) {
        dogIsFetching = fetching
        dogOffsetY = 120
        dogAnim = .appearing
        if !fetching { spawnLaughParticles() }
    }

    // MARK: - Power-ups

    private func activatePowerUp(index: Int) {
        let pu = powerUps[index]
        powerUps[index].collected = true
        switch pu.type {
        case .extraAmmo:
            ammo += 1
            spawnTextParticle(at: pu.position, text: "+1 🔫", color: .yellow)
        case .doubleScore:
            doubleScoreActive = true
            doubleScoreTimer = 10.0
            spawnTextParticle(at: pu.position, text: "×2 SCORE!", color: .orange)
        case .slowMotion:
            slowMotionActive = true
            slowMotionTimer = 5.0
            spawnTextParticle(at: pu.position, text: "SLOW-MO!", color: .cyan)
        }
    }

    private func spawnPowerUp() {
        guard screenSize != .zero else { return }
        let type = PowerUpType.allCases.randomElement()!
        let pu = PowerUp(
            position: CGPoint(
                x: Double.random(in: 60 ... (screenSize.width - 60)),
                y: Double.random(in: 80 ... (screenSize.height * 0.55))
            ),
            type: type
        )
        powerUps.append(pu)
    }

    // MARK: - Particles

    private func spawnHitParticles(at pt: CGPoint, color: Color) {
        for _ in 0 ..< 14 {
            let angle = Double.random(in: 0 ..< .pi * 2)
            let speed = Double.random(in: 90 ... 320)
            particles.append(Particle(
                position: pt,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 80),
                color: color,
                size: Double.random(in: 4 ... 10)
            ))
        }
        // feather specks
        for _ in 0 ..< 7 {
            let angle = Double.random(in: 0 ..< .pi * 2)
            let speed = Double.random(in: 40 ... 140)
            var p = Particle(
                position: pt,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 40),
                color: .white,
                size: Double.random(in: 5 ... 12),
                text: "✦"
            )
            p.life = 0.9
            particles.append(p)
        }
    }

    private func spawnLaughParticles() {
        let base = CGPoint(x: screenSize.width * 0.5, y: screenSize.height * 0.75)
        for (i, word) in ["HA", "HA", "HA!"].enumerated() {
            var p = Particle(
                position: CGPoint(x: base.x + Double(i - 1) * 55, y: base.y),
                velocity: CGVector(dx: Double.random(in: -20 ... 20), dy: -70),
                color: .yellow,
                size: 22,
                text: word
            )
            p.life = 1.4
            particles.append(p)
        }
    }

    private func spawnTextParticle(at pt: CGPoint, text: String, color: Color) {
        var p = Particle(
            position: pt,
            velocity: CGVector(dx: 0, dy: -55),
            color: color,
            size: 18,
            text: text
        )
        p.life = 1.1
        particles.append(p)
    }

    // MARK: - Round management

    private func endRound() {
        guard runState == .playing else { return }
        runState = .roundEnd
        roundEndTimer = 3.2
        if score > highScore { highScore = score }
        let escaped = ducks.filter { $0.state == .escaped }
        if !escaped.isEmpty && dogAnim == .hidden { triggerDog(fetching: false) }
    }

    private func beginNewRound() {
        round += 1
        ammo = 3 + (round > 4 ? 1 : 0)
        ducks.removeAll()
        powerUps.removeAll()
        runState = .playing
        spawnDucks()
    }

    func startGame() {
        score = 0
        round = 1
        ammo = 3
        ducks.removeAll()
        particles.removeAll()
        powerUps.removeAll()
        dogAnim = .hidden
        dogOffsetY = 120
        doubleScoreActive = false
        slowMotionActive = false
        runState = .playing
        spawnDucks()
    }

    // MARK: - Duck spawning

    private func spawnDucks() {
        let count = min(1 + (round - 1) / 2, 5)
        for _ in 0 ..< count { spawnOneDuck() }
    }

    private func spawnOneDuck() {
        let type = pickType()
        let fromLeft = Bool.random()
        let baseSpeed = 80.0 + Double(round) * 14
        let speed: Double
        switch type {
        case .fast:   speed = baseSpeed * 2.2
        case .boss:   speed = baseSpeed * 0.55
        case .zigzag: speed = baseSpeed * 1.15
        default:      speed = baseSpeed
        }

        let x = fromLeft ? -70.0 : screenSize.width + 70
        let y = Double.random(in: 100 ... max(110, screenSize.height * 0.58))

        let health: Int
        switch type {
        case .boss: health = 3
        default:    health = 1
        }

        ducks.append(Duck(
            position: CGPoint(x: x, y: y),
            velocity: CGVector(dx: fromLeft ? speed : -speed, dy: 0),
            type: type,
            health: health
        ))
    }

    private func pickType() -> DuckType {
        let r = Double.random(in: 0 ... 1)
        if round >= 5 && r < 0.14 { return .boss }
        if round >= 3 && r < 0.28 { return .fast }
        if round >= 2 && r < 0.44 { return .zigzag }
        if r < 0.09 { return .decoy }
        return .normal
    }

    // MARK: - Grass setup

    func buildGrass(width: Double) {
        grassBlades.removeAll()
        var x = 0.0
        while x < width {
            grassBlades.append(GrassBlade(
                x: x + Double.random(in: -4 ... 4),
                height: Double.random(in: 14 ... 32),
                lean: Double.random(in: -7 ... 7)
            ))
            x += 11
        }
    }

    // MARK: - Helpers

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - DuckHuntGameView

struct DuckHuntGameView: View {
    @StateObject private var game = GameModel()
    @State private var lastDate = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // ── Game canvas ──────────────────────────────────────────────
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        drawScene(ctx: &ctx, size: size)
                    }
                    .onChange(of: timeline.date) { _, newDate in
                        let dt = newDate.timeIntervalSince(lastDate)
                        lastDate = newDate
                        game.update(dt: dt)
                    }
                }
                .ignoresSafeArea()
                .onTapGesture { location in
                    if game.runState == .start {
                        game.startGame()
                    } else if game.runState == .playing {
                        game.shoot(at: location)
                    }
                }

                // ── HUD overlay ──────────────────────────────────────────────
                if game.runState != .start {
                    HUDView(game: game)
                }

                // ── Start / title screen ─────────────────────────────────────
                if game.runState == .start {
                    StartScreenView()
                }
            }
            .onAppear {
                game.screenSize = geo.size
                game.buildGrass(width: geo.size.width)
            }
            .onChange(of: geo.size) { _, newSize in
                game.screenSize = newSize
                game.buildGrass(width: newSize.width)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Drawing

    private func drawScene(ctx: inout GraphicsContext, size: CGSize) {
        drawBackground(ctx: &ctx, size: size)
        for pu in game.powerUps { drawPowerUp(ctx: &ctx, pu: pu) }
        for duck in game.ducks   { drawDuck(ctx: &ctx, duck: duck) }
        for pt in game.particles  { drawParticle(ctx: &ctx, p: pt) }
        drawDog(ctx: &ctx, size: size)
        if game.crosshairVisible { drawCrosshair(ctx: &ctx, pos: game.crosshairPos) }
        if let flash = game.muzzleFlash { drawMuzzleFlash(ctx: &ctx, pos: flash) }
        drawCRTOverlay(ctx: &ctx, size: size)
    }

    // ── Background ──────────────────────────────────────────────────────────

    private func drawBackground(ctx: inout GraphicsContext, size: CGSize) {
        // Sky
        let skyRect = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height * 0.82))
        ctx.fill(Path(skyRect), with: .color(Color(red: 0.38, green: 0.68, blue: 0.98)))

        // Sun
        let sunC = CGPoint(x: size.width * 0.84, y: size.height * 0.11)
        ctx.fill(Path(ellipseIn: CGRect(x: sunC.x - 30, y: sunC.y - 30, width: 60, height: 60)),
                 with: .color(Color(red: 1.0, green: 0.95, blue: 0.45)))
        // Sun rays
        var rays = Path()
        for i in 0 ..< 8 {
            let angle = Double(i) * .pi / 4
            rays.move(to: CGPoint(x: sunC.x + cos(angle) * 33, y: sunC.y + sin(angle) * 33))
            rays.addLine(to: CGPoint(x: sunC.x + cos(angle) * 44, y: sunC.y + sin(angle) * 44))
        }
        ctx.stroke(rays, with: .color(Color(red: 1.0, green: 0.92, blue: 0.2, opacity: 0.7)), lineWidth: 3)

        // Clouds
        for (cx, cy, sc) in [(size.width * 0.18, size.height * 0.14, 1.1),
                              (size.width * 0.52, size.height * 0.09, 0.85),
                              (size.width * 0.72, size.height * 0.19, 1.0)] {
            drawCloud(ctx: &ctx, center: CGPoint(x: cx, y: cy), scale: sc)
        }

        // Back hills
        var hills = Path()
        hills.move(to: CGPoint(x: 0, y: size.height * 0.72))
        hills.addCurve(
            to: CGPoint(x: size.width, y: size.height * 0.72),
            control1: CGPoint(x: size.width * 0.25, y: size.height * 0.54),
            control2: CGPoint(x: size.width * 0.75, y: size.height * 0.58)
        )
        hills.addLine(to: CGPoint(x: size.width, y: size.height))
        hills.addLine(to: CGPoint(x: 0, y: size.height))
        hills.closeSubpath()
        ctx.fill(hills, with: .color(Color(red: 0.20, green: 0.58, blue: 0.20)))

        // Ground strip
        let groundRect = CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.height * 0.18)
        ctx.fill(Path(groundRect), with: .color(Color(red: 0.14, green: 0.48, blue: 0.14)))

        // Grass blades
        let grassY = size.height * 0.82
        var grassPath = Path()
        for blade in game.grassBlades {
            grassPath.move(to: CGPoint(x: blade.x, y: grassY))
            grassPath.addQuadCurve(
                to: CGPoint(x: blade.x + blade.lean, y: grassY - blade.height),
                control: CGPoint(x: blade.x + blade.lean * 0.5, y: grassY - blade.height * 0.55)
            )
        }
        ctx.stroke(grassPath, with: .color(Color(red: 0.08, green: 0.60, blue: 0.08)), lineWidth: 2)
    }

    private func drawCloud(ctx: inout GraphicsContext, center: CGPoint, scale: Double) {
        let puffs: [(Double, Double, Double)] = [
            (0, 0, 24), (-22, 6, 17), (22, 6, 19), (-38, 13, 13), (38, 13, 15)
        ]
        for (dx, dy, r) in puffs {
            let pr = r * scale
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x + dx * scale - pr,
                                       y: center.y + dy * scale - pr,
                                       width: pr * 2, height: pr * 2)),
                with: .color(.white.opacity(0.88))
            )
        }
    }

    // ── Duck ────────────────────────────────────────────────────────────────

    private func drawDuck(ctx: inout GraphicsContext, duck: Duck) {
        guard duck.state != .escaped else { return }

        let w = duck.size.width
        let h = duck.size.height
        let isHit = duck.state == .hit || duck.state == .falling || duck.state == .dead
        let facingLeft = duck.velocity.dx < 0

        var lCtx = ctx
        // Position at duck center
        lCtx.translateBy(x: duck.position.x, y: duck.position.y)
        // Rotate (during fall)
        if isHit { lCtx.rotate(by: .degrees(duck.rotation)) }
        // Flip if facing left
        if facingLeft { lCtx.concatenate(CGAffineTransform(scaleX: -1, y: 1)) }

        let bc = duck.bodyColor

        // ── Body (ellipse) ──────────────────────────────────────
        let bodyRect = CGRect(x: -w * 0.48, y: -h * 0.28, width: w * 0.96, height: h * 0.56)
        let bodyPath = Path(roundedRect: bodyRect, cornerRadius: h * 0.24)
        lCtx.fill(bodyPath, with: .color(bc))
        lCtx.stroke(bodyPath, with: .color(.black.opacity(0.55)), lineWidth: 2)

        // ── Wing flap ──────────────────────────────────────────
        let wFlap = sin(duck.wingPhase) * 8
        var wing = Path()
        wing.move(to: CGPoint(x: -w * 0.30, y: -h * 0.20))
        wing.addQuadCurve(
            to:      CGPoint(x:  w * 0.25, y: -h * 0.20),
            control: CGPoint(x: 0,          y: -h * 0.50 + wFlap)
        )
        wing.addLine(to: CGPoint(x: w * 0.25, y: h * 0.22))
        wing.addQuadCurve(
            to:      CGPoint(x: -w * 0.30, y: h * 0.22),
            control: CGPoint(x: 0,          y: h * 0.34)
        )
        wing.closeSubpath()
        lCtx.fill(wing, with: .color(bc.opacity(0.65)))
        lCtx.stroke(wing, with: .color(.black.opacity(0.40)), lineWidth: 1.5)

        // ── Head ────────────────────────────────────────────────
        let hR = h * 0.26
        let hCenter = CGPoint(x: w * 0.40, y: -h * 0.35)
        let headPath = Path(ellipseIn: CGRect(x: hCenter.x - hR, y: hCenter.y - hR,
                                               width: hR * 2, height: hR * 2))
        lCtx.fill(headPath, with: .color(bc))
        lCtx.stroke(headPath, with: .color(.black.opacity(0.55)), lineWidth: 2)

        // ── Bill ────────────────────────────────────────────────
        var bill = Path()
        bill.move(to: CGPoint(x: hCenter.x + hR * 0.6, y: hCenter.y - hR * 0.2))
        bill.addLine(to: CGPoint(x: hCenter.x + hR * 1.5, y: hCenter.y + hR * 0.2))
        bill.addLine(to: CGPoint(x: hCenter.x + hR * 0.6, y: hCenter.y + hR * 0.6))
        bill.closeSubpath()
        lCtx.fill(bill, with: .color(.orange))

        // ── Eye ─────────────────────────────────────────────────
        if isHit {
            // X eyes on dead duck
            let ex = hCenter.x - hR * 0.35
            let ey = hCenter.y - hR * 0.15
            let s = CGFloat(4.5)
            var xPath = Path()
            xPath.move(to: CGPoint(x: ex - s, y: ey - s)); xPath.addLine(to: CGPoint(x: ex + s, y: ey + s))
            xPath.move(to: CGPoint(x: ex + s, y: ey - s)); xPath.addLine(to: CGPoint(x: ex - s, y: ey + s))
            lCtx.stroke(xPath, with: .color(.red), lineWidth: 2.5)
        } else {
            let eyeRect = CGRect(x: hCenter.x - hR * 0.6, y: hCenter.y - hR * 0.45, width: hR * 0.55, height: hR * 0.55)
            lCtx.fill(Path(ellipseIn: eyeRect), with: .color(.black))
            // Specular
            let specRect = CGRect(x: hCenter.x - hR * 0.55, y: hCenter.y - hR * 0.50, width: hR * 0.18, height: hR * 0.18)
            lCtx.fill(Path(ellipseIn: specRect), with: .color(.white.opacity(0.7)))
        }

        // ── Neck band (colour accent) ───────────────────────────
        let bandRect = CGRect(x: w * 0.22, y: -h * 0.14, width: hR * 1.2, height: hR * 0.45)
        let bandPath = Path(roundedRect: bandRect, cornerRadius: 3)
        let bandColor: Color = (duck.type == .normal) ? Color(red: 0.0, green: 0.45, blue: 0.12)
                                                       : bc.opacity(0.5)
        lCtx.fill(bandPath, with: .color(bandColor))

        // ── Boss HP bar ─────────────────────────────────────────
        if duck.type == .boss {
            for j in 0 ..< 3 {
                let filled = j < duck.health
                let hpRect = CGRect(x: -w * 0.45 + Double(j) * 17, y: -h * 0.55, width: 13, height: 7)
                lCtx.fill(Path(hpRect), with: .color(filled ? .red : .gray.opacity(0.4)))
                lCtx.stroke(Path(hpRect), with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
        }

        // ── Zigzag stripes ──────────────────────────────────────
        if duck.type == .zigzag {
            var stripes = Path()
            for j in 1 ..< 3 {
                let sx = -w * 0.48 + Double(j) * w * 0.32
                stripes.move(to: CGPoint(x: sx, y: -h * 0.28))
                stripes.addLine(to: CGPoint(x: sx, y: h * 0.28))
            }
            lCtx.stroke(stripes, with: .color(.white.opacity(0.45)), lineWidth: 2)
        }
    }

    // ── Power-up ────────────────────────────────────────────────────────────

    private func drawPowerUp(ctx: inout GraphicsContext, pu: PowerUp) {
        let r = 22.0
        let pos = pu.position
        // Glow
        ctx.fill(Path(ellipseIn: CGRect(x: pos.x - r - 6, y: pos.y - r - 6,
                                         width: (r + 6) * 2, height: (r + 6) * 2)),
                 with: .color(pu.accentColor.opacity(0.22)))
        // Circle
        ctx.fill(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r,
                                         width: r * 2, height: r * 2)),
                 with: .color(pu.accentColor))
        ctx.stroke(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r,
                                           width: r * 2, height: r * 2)),
                   with: .color(.white.opacity(0.8)), lineWidth: 2.5)
        // Label
        ctx.draw(
            Text(pu.label)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundColor(.white),
            at: pos,
            anchor: .center
        )
    }

    // ── Particle ────────────────────────────────────────────────────────────

    private func drawParticle(ctx: inout GraphicsContext, p: Particle) {
        let a = max(0, p.life)
        if let text = p.text {
            // Use a local copy so opacity change doesn't bleed into subsequent draws
            var localCtx = ctx
            localCtx.opacity = a
            localCtx.draw(
                Text(text)
                    .font(.system(size: p.size, weight: .black))
                    .foregroundColor(p.color),
                at: p.position,
                anchor: .center
            )
        } else {
            let half = p.size / 2
            ctx.fill(
                Path(CGRect(x: p.position.x - half, y: p.position.y - half,
                             width: p.size, height: p.size)),
                with: .color(p.color.opacity(a))
            )
        }
    }

    // ── Dog ─────────────────────────────────────────────────────────────────

    private func drawDog(ctx: inout GraphicsContext, size: CGSize) {
        guard game.dogAnim != .hidden else { return }

        let dogX = size.width * 0.5
        let dogY = size.height - 55 + game.dogOffsetY

        var lCtx = ctx
        lCtx.translateBy(x: dogX, y: dogY)

        let brown = Color(red: 0.60, green: 0.38, blue: 0.18)
        let darkBrown = Color(red: 0.42, green: 0.24, blue: 0.10)

        // Body
        lCtx.fill(
            Path(roundedRect: CGRect(x: -28, y: -54, width: 56, height: 44), cornerRadius: 10),
            with: .color(brown)
        )
        // Head
        lCtx.fill(
            Path(roundedRect: CGRect(x: -22, y: -86, width: 44, height: 38), cornerRadius: 12),
            with: .color(brown)
        )
        // Ears
        lCtx.fill(Path(ellipseIn: CGRect(x: -32, y: -94, width: 22, height: 28)), with: .color(darkBrown))
        lCtx.fill(Path(ellipseIn: CGRect(x:  10, y: -94, width: 22, height: 28)), with: .color(darkBrown))

        // Eyes
        if !game.dogIsFetching {
            // Laughing – curved happy eyes
            var laughEye = Path()
            laughEye.move(to: CGPoint(x: -12, y: -66)); laughEye.addQuadCurve(to: CGPoint(x: -4, y: -66), control: CGPoint(x: -8, y: -72))
            laughEye.move(to: CGPoint(x:   4, y: -66)); laughEye.addQuadCurve(to: CGPoint(x: 12, y: -66), control: CGPoint(x:  8, y: -72))
            lCtx.stroke(laughEye, with: .color(.black), lineWidth: 2.5)
        } else {
            // Normal eyes
            lCtx.fill(Path(ellipseIn: CGRect(x: -14, y: -74, width: 9, height: 9)), with: .color(.black))
            lCtx.fill(Path(ellipseIn: CGRect(x:   5, y: -74, width: 9, height: 9)), with: .color(.black))
        }

        // Nose
        lCtx.fill(Path(ellipseIn: CGRect(x: -6, y: -63, width: 12, height: 8)), with: .color(.black))

        // Tail (wagging)
        var tail = Path()
        tail.move(to: CGPoint(x: 28, y: -44))
        tail.addQuadCurve(to: CGPoint(x: 48, y: -66), control: CGPoint(x: 52, y: -44))
        lCtx.stroke(tail, with: .color(brown), lineWidth: 7)

        // Fetched duck above head
        if game.dogIsFetching {
            var duckArc = Path()
            duckArc.move(to: CGPoint(x: -16, y: -102))
            duckArc.addQuadCurve(to: CGPoint(x: 16, y: -102), control: CGPoint(x: 0, y: -118))
            lCtx.stroke(duckArc, with: .color(.white.opacity(0.85)), lineWidth: 5)
            lCtx.fill(Path(ellipseIn: CGRect(x: 12, y: -110, width: 10, height: 10)),
                      with: .color(.orange))
        }

        // Message bubble (draw background rect then text)
        let msg = game.dogIsFetching ? "Got it!" : "HA HA!"
        lCtx.fill(
            Path(roundedRect: CGRect(x: -32, y: -136, width: 64, height: 22), cornerRadius: 5),
            with: .color(.black.opacity(0.60))
        )
        lCtx.draw(
            Text(msg)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundColor(.white),
            at: CGPoint(x: 0, y: -125),
            anchor: .center
        )
    }

    // ── Crosshair ───────────────────────────────────────────────────────────

    private func drawCrosshair(ctx: inout GraphicsContext, pos: CGPoint) {
        let R = 32.0, r = 9.0

        // Outer ring
        ctx.stroke(
            Path(ellipseIn: CGRect(x: pos.x - R, y: pos.y - R, width: R * 2, height: R * 2)),
            with: .color(Color.red.opacity(0.85)),
            lineWidth: 2
        )
        // Cross lines
        var cross = Path()
        cross.move(to: CGPoint(x: pos.x - R, y: pos.y)); cross.addLine(to: CGPoint(x: pos.x - r, y: pos.y))
        cross.move(to: CGPoint(x: pos.x + r, y: pos.y)); cross.addLine(to: CGPoint(x: pos.x + R, y: pos.y))
        cross.move(to: CGPoint(x: pos.x, y: pos.y - R)); cross.addLine(to: CGPoint(x: pos.x, y: pos.y - r))
        cross.move(to: CGPoint(x: pos.x, y: pos.y + r)); cross.addLine(to: CGPoint(x: pos.x, y: pos.y + R))
        ctx.stroke(cross, with: .color(Color.red.opacity(0.85)), lineWidth: 2)

        // Center dot
        ctx.fill(
            Path(ellipseIn: CGRect(x: pos.x - 3.5, y: pos.y - 3.5, width: 7, height: 7)),
            with: .color(.red)
        )
    }

    // ── Muzzle flash ────────────────────────────────────────────────────────

    private func drawMuzzleFlash(ctx: inout GraphicsContext, pos: CGPoint) {
        let fR = 28.0
        ctx.fill(
            Path(ellipseIn: CGRect(x: pos.x - fR, y: pos.y - fR, width: fR * 2, height: fR * 2)),
            with: .color(Color(red: 1.0, green: 0.85, blue: 0.15, opacity: 0.55))
        )
        var rays = Path()
        for i in 0 ..< 8 {
            let a = Double(i) * .pi / 4
            rays.move(to: CGPoint(x: pos.x + cos(a) * fR * 0.5, y: pos.y + sin(a) * fR * 0.5))
            rays.addLine(to: CGPoint(x: pos.x + cos(a) * fR * 1.4, y: pos.y + sin(a) * fR * 1.4))
        }
        ctx.stroke(rays, with: .color(Color(red: 1, green: 0.8, blue: 0.1, opacity: 0.75)), lineWidth: 3)
    }

    // ── CRT overlay ─────────────────────────────────────────────────────────

    private func drawCRTOverlay(ctx: inout GraphicsContext, size: CGSize) {
        // Horizontal scanlines
        var scanlines = Path()
        var y = 0.0
        while y < size.height {
            scanlines.move(to: CGPoint(x: 0, y: y))
            scanlines.addLine(to: CGPoint(x: size.width, y: y))
            y += 4
        }
        ctx.stroke(scanlines, with: .color(.black.opacity(0.07)), lineWidth: 1)

        // Radial vignette – dark at edges, transparent in centre
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerR  = hypot(size.width, size.height) * 0.62
        let vignette = Gradient(colors: [.clear, Color.black.opacity(0.40)])
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(vignette,
                                  center: centre,
                                  startRadius: outerR * 0.38,
                                  endRadius:   outerR)
        )
    }
}

// MARK: - HUD

struct HUDView: View {
    @ObservedObject var game: GameModel

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                // Score
                VStack(alignment: .leading, spacing: 1) {
                    Text("SCORE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.85))
                    Text("\(game.score)")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.52))
                .cornerRadius(8)

                Spacer()

                // Round
                VStack(spacing: 1) {
                    Text("ROUND")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.85))
                    Text("\(game.round)")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.52))
                .cornerRadius(8)

                Spacer()

                // Ammo
                VStack(alignment: .trailing, spacing: 3) {
                    Text("AMMO")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.85))
                    HStack(spacing: 4) {
                        // Show up to 6 filled circles for current ammo
                        let display = min(game.ammo, 6)
                        ForEach(0 ..< max(display, 0), id: \.self) { _ in
                            Circle().fill(Color.red).frame(width: 11, height: 11)
                        }
                        // Empty circles to fill up to 3 if below base ammo
                        let emptyCount = max(3 - game.ammo, 0)
                        ForEach(0 ..< emptyCount, id: \.self) { _ in
                            Circle().strokeBorder(Color.red.opacity(0.4), lineWidth: 1.5).frame(width: 11, height: 11)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.52))
                .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 54)

            // Active power-up indicators
            if game.doubleScoreActive || game.slowMotionActive {
                HStack(spacing: 8) {
                    if game.doubleScoreActive {
                        Text("×2 SCORE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(5)
                    }
                    if game.slowMotionActive {
                        Text("SLOW-MO")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(5)
                    }
                }
            }
        }
    }
}

// MARK: - Start Screen

struct StartScreenView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()

            VStack(spacing: 18) {
                Text("DUCK HUNT")
                    .font(.system(size: 48, weight: .black, design: .monospaced))
                    .foregroundColor(.yellow)
                    .shadow(color: .orange, radius: 12)

                Text("METAL")
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .foregroundColor(.orange)
                    .shadow(color: .red, radius: 8)

                Text("🦆")
                    .font(.system(size: 56))
                    .rotationEffect(.degrees(pulse ? 12 : -12))
                    .animation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

                VStack(spacing: 6) {
                    instructionRow("Tap screen to shoot")
                    instructionRow("Hit ducks for points")
                    instructionRow("3 shots per round")
                    instructionRow("Catch ✦ power-ups!")
                }

                Text("TAP TO START")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Color.green.opacity(0.78))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 2))
                    .scaleEffect(pulse ? 1.06 : 0.95)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
            }
            .padding(30)
        }
    }

    private func instructionRow(_ text: String) -> some View {
        Text("• \(text)")
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.92))
    }
}

// MARK: - ContentView (wrapper)

struct ContentView: View {
    var body: some View {
        DuckHuntGameView()
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
