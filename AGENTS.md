# AGENTS.md — Meow Agent Design System & UI Consistency Rules

## Purpose

This document defines the visual identity, layout rules, spacing system, interaction behavior, and UI philosophy for Meow Agent.

All coding/design agents working on this project MUST follow this document to maintain a consistent experience across the entire application.

Meow Agent is NOT:

* a developer dashboard
* a terminal app
* an enterprise admin panel
* a hacker-style UI

Meow Agent IS:

> a modern Android-native AI companion operating system.

The app should feel:

* calm
* futuristic
* lightweight
* ambient
* premium
* minimal
* approachable

Inspired by:

* OpenAI Mobile
* Arc Search
* Linear
* Perplexity
* Raycast
* Nothing OS
* visionOS floating surfaces

---

# CORE DESIGN PRINCIPLES

## 1. Controlled Emptiness

The UI must breathe.

Do NOT stack elements tightly.
Do NOT overfill the screen.

Good UI in Meow Agent relies heavily on:

* spacing
* rhythm
* hierarchy
* subtle contrast

The app should feel:

> spacious but intentional.

---

## 2. Floating Surfaces

Most UI components should feel detached from the background.

Use:

* floating cards
* rounded surfaces
* soft shadows
* translucent layers
* subtle depth

Avoid:

* flat harsh containers
* heavy separators
* rigid dashboard layouts

---

## 3. Soft Futuristic

The app should feel futuristic WITHOUT:

* cyberpunk overload
* neon everywhere
* hacker aesthetics
* excessive gradients

Target:

> ambient AI operating system.

---

## 4. Calm Interaction

Animations and transitions must feel:

* smooth
* subtle
* premium
* lightweight

Avoid:

* aggressive bounce
* flashy transitions
* exaggerated motion

---

# GLOBAL STYLE RULES

## Background

Primary background:

```txt
#020817
```

Background must remain:

* dark navy
* deep
* clean
* minimal

Do NOT use:

* pure black
* colorful backgrounds
* busy textures

---

# COLOR SYSTEM

## Primary Blue

```txt
#3B82F6
```

Used for:

* active states
* focused inputs
* chat FAB
* primary actions

---

## Surface

```txt
rgba(15,23,42,0.82)
```

Used for:

* cards
* modals
* bottom dock
* floating containers

---

## Text Colors

Primary text:

```txt
#E5E7EB
```

Secondary text:

```txt
#94A3B8
```

Muted/inactive:

```txt
#64748B
```

---

## Borders

Borders must be subtle.

Preferred:

```txt
rgba(255,255,255,0.05)
```

Never use:

* thick borders
* bright outlines
* hard dividers

---

# SPACING SYSTEM

## Most Important Rule

Spacing consistency is critical.

The app should NEVER feel cramped.

---

# Vertical Rhythm

Recommended spacing:

## Section Title → Section Subtitle

```txt
10–14px
```

## Subtitle → Input Field

```txt
8–10px
```

## Input → Input

```txt
14–18px
```

## Section → Section

```txt
24–32px
```

## Card Internal Padding

```txt
18–24px
```

---

# SAFE AREA RULES

Always support:

* Android edge-to-edge
* gesture navigation
* floating bottom dock

Critical:
UI elements must NEVER collide with:

* Android gesture area
* virtual navigation bar
* floating FAB

Use SafeArea properly.

Bottom padding should feel intentional and breathable.

---

# TYPOGRAPHY RULES

Typography should feel:

* modern
* calm
* highly readable
* soft

Avoid:

* overly bold typography
* giant headings
* compressed text

---

# Typography Hierarchy

## Screen Title

* medium weight
* slightly emphasized
* never oversized

## Section Title

* subtle emphasis
* clean spacing

## Field Labels

* small
* muted
* secondary hierarchy

## Body Text

* clean
* readable
* relaxed line height

---

# CONTAINER RULES

All surfaces should use:

* large rounded corners
* subtle depth
* soft translucent backgrounds

Avoid:

* flat rectangles
* harsh cards
* Material default appearance

---

# Rounded Radius

Preferred:

```txt
20–28px
```

Floating dock:

```txt
999px (pill shape)
```

FAB:

```txt
fully circular
```

---

# SHADOW RULES

Shadows must be:

* soft
* ambient
* subtle

Avoid:

* dark hard shadows
* excessive blur
* dramatic elevation

Goal:

> floating AI surfaces.

---

# INPUT FIELD RULES

Inputs must:

* feel soft
* modern
* premium
* calm

Input containers:

* rounded
* slightly translucent
* subtle gradient
* faint inner highlight

Avoid:

* Flutter default TextField appearance
* thick borders
* enterprise form styling

---

# INPUT FOCUS STATE

Focused input should:

* softly glow blue
* slightly brighten border
* feel ambient

Do NOT use:

* harsh blue outlines
* Material default focus

---

# BUTTON RULES

Buttons should:

* feel soft and premium
* use subtle gradients
* have rounded corners
* minimal elevation

Primary CTA:

* blue accent
* subtle glow
* clean typography

Avoid:

* bulky buttons
* enterprise buttons
* excessive shadows

---

# BOTTOM NAVIGATION RULES

Bottom navigation uses:

* floating dock style
* full pill shape
* translucent surface
* soft blur

The dock must:

* float above bottom edge
* respect SafeArea
* never touch Android gesture area

---

# CHAT FAB RULES

The center Chat button is:

> the heart of the app.

It should:

* be the most visually important navigation item
* slightly larger than others
* softly glowing
* premium and calm

Avoid:

* giant oversized FAB
* aggressive neon glow
* cartoonish bounce

---

# ICON RULES

Icons must:

* use consistent stroke weight
* be minimal
* modern
* slightly rounded

Avoid mixing:

* filled
* outline
* thin
* thick

icon styles randomly.

---

# CARD DESIGN RULES

Cards should feel:

* interactive
* lightweight
* floating

Use:

* translucent navy surfaces
* subtle border
* soft shadow
* rounded corners

Avoid:

* giant dashboard cards
* excessive padding
* rigid grid systems

---

# EMPTY STATE RULES

Empty states should:

* educate naturally
* feel friendly
* guide the user

Avoid:

* technical language
* cold placeholders
* generic empty boxes

Preferred structure:

```txt
Icon / Illustration

Title
Description

Primary Action
```

---

# MOTION RULES

Animations must feel:

* soft
* elegant
* premium
* ambient

Recommended:

* fade
* smooth slide
* subtle scale
* gentle glow pulse

Avoid:

* spring explosions
* exaggerated bounce
* flashy transitions

---

# DEVELOPMENT RULES

## Flutter Guidelines

Optimize for:

* Flutter Material 3
* reusable widgets
* dark mode first
* responsive layouts
* edge-to-edge Android

---

# COMPONENT SYSTEM

Reusable components should exist for:

* AppScaffold
* FloatingDock
* ChatFAB
* GlassCard
* MeowTextField
* SectionHeader
* SettingsTile
* ModuleCard
* EmptyStateCard
* PrimaryButton

Avoid duplicated styling.

---

# DESIGN PHILOSOPHY

Every screen should feel like:

> “You are interacting with an ambient AI operating system.”

NOT:

* server management software
* Android settings app
* terminal wrapper
* cyberpunk dashboard

The UI should communicate:

* intelligence
* calmness
* safety
* modernity
* simplicity

---

# FINAL RULE

When designing anything in Meow Agent, always ask:

> “Does this feel like a calm futuristic AI companion?”

If the answer is no:
simplify it.
