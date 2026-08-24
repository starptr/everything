//! End-to-end tests for the checkout-less `local-*` workstream kinds: creation
//! (where the directory comes from), the per-kind removal policy, and spawnability.
//! No network or `jj` — these kinds never invoke the checkout provider.

mod common;

use std::fs;
use std::path::Path;

use common::{new_local_blank, new_local_tmp, new_local_unmanaged, temp_forest, FakeOk};
use silverwood_core::{
    Error, Forest, LocationWithinForest, SessionKind, SpawnSeed, Status, Workstream,
};

/// The recorded directory of a workstream (every kind has exactly one location).
fn dir_of(ws: &Workstream) -> String {
    let LocationWithinForest::BasicForest { path } = &ws.body.location().unwrap().within else {
        unreachable!("a basic-forest location");
    };
    path.clone()
}

#[test]
fn local_blank_creates_empty_in_forest_dir_no_mode() {
    let dir = temp_forest("blank-create");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    let ws = forest.create_workstream(new_local_blank("blank")).unwrap();
    assert_eq!(ws.body.kind.tag(), "local-blank");
    assert_eq!(ws.body.overall_state(), "active - local-blank");
    assert!(ws.body.mode().is_none(), "no checkout mode");

    let path = dir_of(&ws);
    assert!(
        Path::new(&path).starts_with(dir.join("working-copies")),
        "blank dir lives under the forest's working-copies: {path}"
    );
    assert!(Path::new(&path).is_dir(), "the empty dir was created");
    assert_eq!(fs::read_dir(&path).unwrap().count(), 0, "and is empty");

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn local_tmp_creates_tmp_dir_no_mode() {
    let dir = temp_forest("tmp-create");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    let ws = forest.create_workstream(new_local_tmp("tmp")).unwrap();
    assert_eq!(ws.body.kind.tag(), "local-tmp");
    assert!(ws.body.mode().is_none());

    let path = dir_of(&ws);
    assert!(
        Path::new(&path).starts_with("/tmp"),
        "tmp dir lives under /tmp: {path}"
    );
    assert!(Path::new(&path).is_dir());

    let _ = fs::remove_dir_all(&path); // outside the forest — clean up explicitly
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn local_unmanaged_adopts_existing_path_no_mode() {
    let dir = temp_forest("adopt-create");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    // An existing dir on the same filesystem as the forest (both under temp_dir()).
    let adopted = temp_forest("adopt-target");
    fs::create_dir_all(&adopted).unwrap();

    let ws = forest
        .create_workstream(new_local_unmanaged("adopt", adopted.to_str().unwrap()))
        .unwrap();
    assert_eq!(ws.body.kind.tag(), "local-unmanaged-existing-path");
    assert!(ws.body.mode().is_none());
    assert_eq!(dir_of(&ws), adopted.to_str().unwrap(), "adopted verbatim");

    // A non-existent path is rejected up front (nothing persisted).
    let missing = adopted.join("does-not-exist");
    let err = forest
        .create_workstream(new_local_unmanaged("bad", missing.to_str().unwrap()))
        .unwrap_err();
    assert!(matches!(err, Error::InvalidSource(_)));
    assert_eq!(
        forest.list(false).unwrap().len(),
        1,
        "the bad create didn't persist"
    );

    let _ = fs::remove_dir_all(&adopted);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn local_unmanaged_removal_is_forbidden_even_with_force() {
    let dir = temp_forest("adopt-remove");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    let adopted = temp_forest("adopt-remove-target");
    fs::create_dir_all(&adopted).unwrap();
    let ws = forest
        .create_workstream(new_local_unmanaged("adopt", adopted.to_str().unwrap()))
        .unwrap();

    // Neither plain nor --force can remove it, and the adopted dir is never touched.
    for force in [false, true] {
        assert!(
            matches!(
                forest.remove(ws.id, force).unwrap_err(),
                Error::RemovalUnsupported(_)
            ),
            "removal forbidden (force={force})"
        );
        assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Active);
        assert!(adopted.is_dir(), "adopted dir must survive (force={force})");
    }

    let _ = fs::remove_dir_all(&adopted);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn local_tmp_removal_needs_force_unless_dir_gone() {
    let dir = temp_forest("tmp-remove");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    // While the dir exists, plain remove refuses; --force deletes the dir + tombstones.
    let ws = forest.create_workstream(new_local_tmp("tmp1")).unwrap();
    let path = dir_of(&ws);
    assert!(matches!(
        forest.remove(ws.id, false).unwrap_err(),
        Error::UnsafeToRemove(_)
    ));
    assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Active);
    assert!(Path::new(&path).is_dir(), "refused remove keeps the dir");

    forest.remove(ws.id, true).unwrap();
    assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Deleted);
    assert!(!Path::new(&path).exists(), "--force deletes the tmp dir");

    // Once the dir is already gone, plain remove proceeds.
    let ws2 = forest.create_workstream(new_local_tmp("tmp2")).unwrap();
    let path2 = dir_of(&ws2);
    fs::remove_dir_all(&path2).unwrap();
    forest.remove(ws2.id, false).unwrap();
    assert_eq!(forest.get(ws2.id).unwrap().body.status, Status::Deleted);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn local_blank_removal_needs_force_unless_empty() {
    let dir = temp_forest("blank-remove");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    // Empty ⇒ plain remove proceeds and deletes the dir.
    let empty = forest.create_workstream(new_local_blank("empty")).unwrap();
    let empty_path = dir_of(&empty);
    forest.remove(empty.id, false).unwrap();
    assert_eq!(forest.get(empty.id).unwrap().body.status, Status::Deleted);
    assert!(!Path::new(&empty_path).exists());

    // Non-empty ⇒ plain remove refuses; --force deletes the whole tree.
    let used = forest.create_workstream(new_local_blank("used")).unwrap();
    let used_path = dir_of(&used);
    fs::write(Path::new(&used_path).join("work.txt"), b"in progress").unwrap();
    assert!(matches!(
        forest.remove(used.id, false).unwrap_err(),
        Error::UnsafeToRemove(_)
    ));
    assert_eq!(forest.get(used.id).unwrap().body.status, Status::Active);
    assert!(
        Path::new(&used_path).is_dir(),
        "refused remove keeps the dir"
    );

    forest.remove(used.id, true).unwrap();
    assert_eq!(forest.get(used.id).unwrap().body.status, Status::Deleted);
    assert!(!Path::new(&used_path).exists());

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn local_kinds_are_spawnable_while_their_dir_exists() {
    let dir = temp_forest("blank-spawn");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let claude = temp_forest("blank-spawn-claude"); // empty ⇒ no transcript

    let ws = forest
        .create_workstream(new_local_blank("spawnable"))
        .unwrap();
    let cwd = dir_of(&ws);
    let seed = SpawnSeed {
        home: "/home/x".into(),
        user: Some("x".into()),
        shell: "/bin/zsh".into(),
        term: None,
        ssh_auth_sock: None,
    };

    // A session runs in the blank directory — it is ready as soon as it exists.
    forest
        .create_session(ws.id, "sh-1", SessionKind::PlainShell {}, "sh")
        .unwrap();
    let plan = forest
        .spawn_plan_from_session(ws.id, "sh-1", &seed, &claude)
        .unwrap();
    assert_eq!(plan.program, "/bin/zsh");
    assert_eq!(plan.cwd, cwd);

    // Once the directory is gone, it is no longer spawnable.
    fs::remove_dir_all(&cwd).unwrap();
    assert!(matches!(
        forest
            .spawn_plan_from_session(ws.id, "sh-1", &seed, &claude)
            .unwrap_err(),
        Error::NotSpawnable { .. }
    ));

    let _ = fs::remove_dir_all(&dir);
    let _ = fs::remove_dir_all(&claude);
}
