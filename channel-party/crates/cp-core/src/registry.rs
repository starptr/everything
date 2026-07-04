//! The two kind registries plus registered runtime components and kind-owned migrations. Explicit
//! registration (over `inventory`-style auto-registration) is chosen for clarity, testability, and
//! control over ordering. See DESIGN §10.

use std::collections::HashMap;
use std::sync::Arc;

use cp_model::{ChannelKind, ItemKind, Migration, Migrations, RuntimeComponent, TypeId};

/// The resolved registry: two type-keyed kind tables, the runtime components, and all migrations.
/// Cloneable (cheap: trait objects behind `Arc`) so it can be shared by core and the frontend. §10.
#[derive(Clone, Default)]
pub struct Registry {
    channels: HashMap<TypeId, Arc<dyn ChannelKind>>,
    items: HashMap<TypeId, Arc<dyn ItemKind>>,
    runtimes: Vec<Arc<dyn RuntimeComponent>>,
    migrations: Vec<Migration>,
}

impl Registry {
    pub fn builder() -> RegistryBuilder {
        RegistryBuilder::default()
    }

    /// The channel kind for a type, or `None` if unregistered.
    pub fn channel(&self, type_id: &TypeId) -> Option<&Arc<dyn ChannelKind>> {
        self.channels.get(type_id)
    }

    /// The item kind for a type, or `None` if unregistered.
    pub fn item(&self, type_id: &TypeId) -> Option<&Arc<dyn ItemKind>> {
        self.items.get(type_id)
    }

    pub fn runtimes(&self) -> &[Arc<dyn RuntimeComponent>] {
        &self.runtimes
    }

    pub fn migrations(&self) -> &[Migration] {
        &self.migrations
    }
}

/// Fluent builder mirroring the composition-root example in DESIGN §10.
#[derive(Default)]
pub struct RegistryBuilder {
    inner: Registry,
}

impl RegistryBuilder {
    /// Register one channel kind, keyed by its `type_id()`.
    pub fn channel(mut self, kind: impl ChannelKind + 'static) -> Self {
        self.inner
            .channels
            .insert(kind.type_id().clone(), Arc::new(kind));
        self
    }

    /// Register one item kind, keyed by its `type_id()`.
    pub fn item(mut self, kind: impl ItemKind + 'static) -> Self {
        self.inner
            .items
            .insert(kind.type_id().clone(), Arc::new(kind));
        self
    }

    /// Register many channel kinds at once (e.g. a namespace crate's `channels()`).
    pub fn channels(mut self, kinds: impl IntoIterator<Item = Box<dyn ChannelKind>>) -> Self {
        for kind in kinds {
            let kind: Arc<dyn ChannelKind> = Arc::from(kind);
            self.inner.channels.insert(kind.type_id().clone(), kind);
        }
        self
    }

    /// Register many item kinds at once.
    pub fn items(mut self, kinds: impl IntoIterator<Item = Box<dyn ItemKind>>) -> Self {
        for kind in kinds {
            let kind: Arc<dyn ItemKind> = Arc::from(kind);
            self.inner.items.insert(kind.type_id().clone(), kind);
        }
        self
    }

    /// Register a runtime component (crate-contributed singleton). §7.
    pub fn runtime(mut self, component: impl RuntimeComponent + 'static) -> Self {
        self.inner.runtimes.push(Arc::new(component));
        self
    }

    /// Register a crate's kind-owned migrations. §6.
    pub fn migrations(mut self, migrations: Migrations) -> Self {
        self.inner.migrations.extend(migrations.0.iter().copied());
        self
    }

    pub fn build(self) -> Registry {
        self.inner
    }
}
