# FDFO Blog Project — Session Notes

## What This Is

An interactive blog post for the FDFO (Flow Derivative Free Optimization) paper, built on the **al-folio** Jekyll template using the **distill** layout. The goal is to create rich interactive visualizations that explain key concepts from the paper.

The paper PDF and related materials are in `paper/`.

## Repo Structure

```
fdfo-blog/
├── _posts/2025-07-01-fdfo.md          # Main blog post (distill layout)
├── assets/plotly/                       # Interactive HTML visualizations
│   ├── fdfo_jacobian_flow.html         # Fractal Jacobian flow viz (main piece)
│   ├── fdfo_halfspace_3d.html          # 3D PSD half-space condition viz
│   ├── fdfo_flow_animation.html        # Flow matching animation
│   ├── fdfo_conceptual_*.html          # Conceptual diagrams
│   └── fdfo_reward_landscape.html      # Reward landscape viz
├── assets/img/                          # Static images for the post
├── paper/                               # Paper PDF and source materials
├── docs/                                # Director agent documentation
│   ├── agent-company.md                # Multi-team agent hierarchy architecture
│   ├── director-directives.md          # Standing rules and quality standards
│   └── making-agent-teams.md           # Role catalog and data flow patterns
├── .claude/
│   ├── agents/director.md              # Director agent definition
│   ├── commands/                        # Slash commands (director, hq, secretaries, etc.)
│   └── hooks/                           # 11 shell scripts for director infrastructure
├── IMG_1558.jpeg                        # Art print reference for color palette
└── _config.yml                          # Jekyll config
```

## Blog Post Structure

The blog post at `_posts/2025-07-01-fdfo.md` uses al-folio's distill layout. Key things:

- **Embedding visualizations**: Use `{% include figure.liquid %}` or raw `<iframe>` tags with container classes
- **Container classes**: `.l-page` (full width), `.l-body` (body width); add `tall` class for taller iframes
- **Current sections**: Intro, flow matching basics, reward landscape, Jacobian transport, PSD condition (3D half-space), conceptual diagrams
- **The content is still mostly bullet points** — needs to be fleshed out into prose

## Key Visualizations

### Fractal Jacobian Flow (`fdfo_jacobian_flow.html`)

The centerpiece interactive viz. Shows how the Jacobian transports reward gradients along an ODE sampling path on a fractal tree distribution.

**Current state**: Working well with the art-print color palette on cream background.

**Key technical details**:
- **Variance-Exploding (VE) schedule**: `x_t = x_1 + σ(t)·ε` where `σ(t) = SIGMA_MAX*(1-t)`, SIGMA_MAX=1.0
- Data means stay at `μ_k` for ALL t (never scaled) — this is critical for the posterior naturally selecting the nearest branch
- **Flow velocity**: `v(x,t) = (E[x_1|x_t] - x_t) / (1-t)` with Bayesian posterior over ~2032 Gaussian mixture components
- **Jacobian**: Backward finite-difference accumulation `J_cum(s) = J_cum(s+1) * (I + dt * dv/dx_s)` with h=5e-4
- **Rendering**: 5-pass vector-based canvas drawing (ellipse halos, wide glow, medium glow, tapered quads, center highlights) — NOT rasterized density
- **Fractal params**: From NVlabs/edm2 `toy_example.py` — origin=[0.0030, 0.0325], scale=[1.3136, 1.3844], seed=2, depth=7
- **Slider**: 200 positions mapping to 20 ODE steps with linear interpolation for smooth movement
- **Play animation**: requestAnimationFrame at 4 steps/second

**Lessons learned the hard way**:
- Standard flow matching schedule `x_t = (1-t)x₀ + t·x₁` with N(0,I) prior does NOT map x₀ to the nearest branch — the prior carries no branch info at t=0
- `snapNearBranch` hacks (clamping clicks to nearest component) cause jumpiness — remove them, VE schedule handles it naturally
- Rasterized MoG density at 500x500 still looks fuzzy — vector-based tree rendering using the known recursive structure looks much better
- Branch taper decay needs to be gentle (0.88^depth, not 0.56^depth) or tips become invisible

### 3D Half-Space (`fdfo_halfspace_3d.html`)

Three.js visualization of the PSD Jacobian condition: valid descent directions stay within 90° of the true gradient.

**Current state**: Toon/paper figure style with FPO colors.

**Key details**:
- MeshBasicMaterial (flat, no lighting/shading) for toon style
- Colors: steel blue `0x2979B9` (valid), warm orange-red `0xE05D36` (invalid), navy `0x18327E`
- Auto-rotating camera at 35° elevation
- Solid colored disc boundary, thick arrows (shaft 0.055, head 0.14)

## Color Palette

Inspired by `IMG_1558.jpeg` (Inuit-style circular art print with cream paper and bold organic shapes):

| Color | Hex | Usage |
|-------|-----|-------|
| Dark navy | `#050532` | Tree trunk, ODE path, UI borders, text |
| Burgundy | `#732424` | Play button accent, high-angle arrows |
| Slate grey | `#656C75` | Captions, secondary text |
| Terracotta | `#AB8064` | Tree tips, mid-angle arrows |
| Cream (bg) | `#FAF8F5` | Background |

The fractal tree branches interpolate from `#050532` (trunk) to `#AB8064` (tips). Arrow colors are angle-dependent: `#050532` (0°) → `#AB8064` (45°) → `#732424` (90°).

The 3D half-space viz uses a DIFFERENT palette (FPO colors: steel blue, orange-red, navy). These haven't been unified yet.

## Jekyll / al-folio

- **Run server**: `bundle exec jekyll serve` from repo root (port 4000)
- Do NOT use `--no-livereload` — this Jekyll version doesn't support that flag
- Build takes ~15-16 seconds; ImageMagick `convert` errors are non-fatal (missing on this system)
- PATH needs: `/opt/homebrew/opt/ruby/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin`
- Livereload port 35729 can conflict if old processes linger — kill them first

## Director Skill

Just pulled in from `lab42/src/abc` branch `arthur/mar9/director`. This is a multi-agent orchestration framework:

- `/director` bootstraps an HQ session with 3 secretaries (git, comms, knowledge)
- `/hq` is the subcommand router (launch, send, broadcast, inbox, merge, report)
- Teams run in separate git worktrees, each in its own tmux window
- The director is purely managerial — never writes code or runs experiments
- **The hooks reference abc-specific paths and conventions** — they'll need adaptation for this project

To use: start Claude Code from this directory inside a tmux session, then invoke `/director`.

## Paper Mapping

The paper covers these key concepts (mapped to blog sections):
1. **Flow matching** — learning velocity fields to transport noise → data
2. **Reward optimization** — using reward gradients to steer generation
3. **Jacobian transport** — how the flow Jacobian maps reward gradients back through the sampling chain
4. **PSD condition** — the Jacobian must preserve descent direction (< 90° from true gradient)
5. **FDFO algorithm** — finite-difference approximation to avoid computing full Jacobians

Each concept has (or should have) an interactive visualization in `assets/plotly/`.
