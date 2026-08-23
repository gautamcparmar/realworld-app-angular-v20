# ![RealWorld](https://raw.githubusercontent.com/gothinkster/realworld/main/media/realworld.png)

# Conduit — RealWorld Example App · Angular v20

> A fully featured social blogging platform (Medium.com clone) built with **Angular v20**, demonstrating modern Angular architecture including Signals, standalone components, and the latest Angular CLI tooling.

This codebase was created to demonstrate a fully fledged application built with Angular that interacts with an actual backend server including CRUD operations, authentication, routing, pagination, and more.

For more information on how this works with other frontends/backends, head over to the [RealWorld repo](https://github.com/gothinkster/realworld).

---

## Tech Stack

| Technology | Version | Purpose |
|---|---|---|
| Angular | 20.x | Core framework |
| Angular CLI | 20.3.1 | Project scaffolding & tooling |
| TypeScript | 5.x | Language |
| RxJS | 7.x | Reactive programming |
| PostCSS | — | CSS processing |

---

## Features

The application implements the full [RealWorld frontend spec](https://realworld-docs.netlify.app/docs/specs/frontend-specs/templates), including:

- **Authentication** — JWT-based login and registration, persisted across sessions
- **Article Feed** — Global feed and personalised feed for authenticated users
- **Article CRUD** — Create, read, update, and delete articles with Markdown support
- **Comments** — Add and delete comments on articles
- **Tags** — Filter the global feed by tag
- **User Profiles** — View profiles and authored/favourited articles
- **Follow Users** — Follow/unfollow other authors
- **Favourite Articles** — Like and unlike articles
- **Settings** — Update user profile, avatar, bio, and password
- **Pagination** — Paginated article lists throughout

---

## Angular v20 Implementation Highlights

This project leverages the latest Angular features available in v20:

### Standalone Components
All components are standalone — there are no `NgModule` declarations. Components, directives, and pipes are imported directly where needed, resulting in a flatter, more tree-shakeable architecture.

### Angular Signals
State management is handled using Angular's built-in **Signals API** (`signal()`, `computed()`, `effect()`) in place of traditional RxJS-only patterns. This provides fine-grained reactivity and simpler change detection without requiring zone.js for most interactions.

### Functional Route Guards & Interceptors
Authentication guards and HTTP interceptors are written as plain functions rather than classes, following the modern Angular style introduced with v15+ and now the convention in v20.

### inject() Function
Dependency injection throughout the app uses the `inject()` function rather than constructor injection, making services and utilities composable outside of class constructors.

### Signal-based Inputs & Outputs
Where applicable, components use the new `input()` and `output()` functions (signal-based component API) for cleaner, more type-safe component interfaces.

### Lazy-Loaded Routes
All feature areas use lazy-loaded routes via `loadComponent()` and `loadChildren()`, keeping the initial bundle small.

---

## Project Structure

```
src/
├── app/
│   ├── core/                  # Singleton services, interceptors, guards
│   │   ├── auth/              # Auth service, JWT handling
│   │   ├── interceptors/      # HTTP interceptors (auth token, error handling)
│   │   └── guards/            # Route guards (auth, no-auth)
│   ├── features/              # Lazy-loaded feature modules
│   │   ├── home/              # Home feed (global + personal)
│   │   ├── article/           # Article view & comments
│   │   ├── editor/            # Article create & edit
│   │   ├── profile/           # User profile pages
│   │   ├── auth/              # Login & registration
│   │   └── settings/          # User settings
│   ├── shared/                # Reusable components, pipes, directives
│   │   ├── components/        # Article list, pagination, tag list, etc.
│   │   └── pipes/             # Markdown, date formatting, etc.
│   ├── app.component.ts       # Root component
│   ├── app.config.ts          # Application configuration (provideRouter, etc.)
│   └── app.routes.ts          # Top-level route definitions
├── environments/              # Environment configuration
└── styles/                    # Global styles
```

---

## Prerequisites

- **Node.js** 18.x or later (LTS recommended)
- **npm** 9.x or later
- **Angular CLI** 20.x

Install the Angular CLI globally if you haven't already:

```bash
npm install -g @angular/cli@20
```

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/TomislavVinkovic/realworld-app-angular-v20.git
cd realworld-app-angular-v20
```

### 2. Install dependencies

```bash
npm install
```

### 3. Start the development server

```bash
ng serve
```

The application will be available at **[http://localhost:4200](http://localhost:4200)**. The dev server supports Hot Module Replacement (HMR) — changes to source files are reflected in the browser automatically.

---

## Available Scripts

| Command | Description |
|---|---|
| `ng serve` | Start the development server on port 4200 |
| `ng build` | Build the application for production |
| `ng build --watch` | Build in watch mode (incremental rebuilds) |
| `ng test` | Run unit tests with Karma |
| `ng lint` | Lint the codebase |
| `ng generate component <name>` | Generate a new standalone component |

### Production Build

```bash
ng build
```

Build artifacts are output to the `dist/` directory. The production build is fully optimised — code splitting, tree shaking, and minification are all applied automatically.

---

## API

The application targets the public RealWorld API. The base URL is configured in the environment files:

```
src/environments/environment.ts          # Development
src/environments/environment.prod.ts     # Production
```

To point the app at your own backend, update the `apiUrl` value in the relevant environment file:

```typescript
export const environment = {
  production: false,
  apiUrl: 'https://your-backend-url/api'
};
```

Any backend that implements the [RealWorld API spec](https://realworld-docs.netlify.app/docs/specs/backend-specs/introduction) is compatible.

---

## Contributing

Contributions are welcome. Please open an issue or submit a pull request.

---

## License

MIT
