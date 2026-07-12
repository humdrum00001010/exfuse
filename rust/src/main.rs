use std::cmp::min;
use std::collections::HashMap;
use std::env;
use std::ffi::{CStr, CString};
use std::io::{self, Read, Write};
use std::mem;
use std::os::raw::{c_char, c_int, c_uint, c_ulong, c_void};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, mpsc};
use std::thread;
use std::time::Duration;

const MAGIC: u32 = 0xC021_55AC;
const PROTOCOL_V2: u32 = 0x7632_0002;

#[repr(u32)]
#[derive(Clone, Copy)]
enum Message {
    Readdir = 3,
    Getattr = 4,
    Readlink = 5,
    Read = 6,
    Write = 7,
    Open = 8,
    Create = 9,
    Truncate = 10,
    Unlink = 11,
    Rename = 12,
    Mkdir = 13,
    Rmdir = 14,
    Chmod = 15,
    Chown = 16,
    Flush = 17,
    Release = 18,
    Fsync = 19,
    Status = 100,
}

impl Message {
    fn code(self) -> u32 {
        self as u32
    }
}

enum NodeKind {
    Dir,
    File,
    Symlink,
}

impl NodeKind {
    fn from_wire(value: u32) -> Option<Self> {
        match value {
            1 => Some(Self::Dir),
            2 => Some(Self::File),
            3 => Some(Self::Symlink),
            _ => None,
        }
    }

    fn fuse_mode(&self) -> libc::mode_t {
        match self {
            Self::Dir => libc::S_IFDIR,
            Self::File => libc::S_IFREG,
            Self::Symlink => libc::S_IFLNK,
        }
    }
}

static PORT: OnceLock<Port> = OnceLock::new();

const SETATTR_MODE: i32 = 1 << 0;
const SETATTR_UID: i32 = 1 << 1;
const SETATTR_GID: i32 = 1 << 2;
const SETATTR_SIZE: i32 = 1 << 3;

type FuseFillDir = Option<
    unsafe extern "C" fn(*mut c_void, *const c_char, *const libc::stat, libc::off_t) -> c_int,
>;

#[repr(C)]
struct FuseOperations {
    getattr: Option<unsafe extern "C" fn(*const c_char, *mut libc::stat) -> c_int>,
    readlink: Option<unsafe extern "C" fn(*const c_char, *mut c_char, usize) -> c_int>,
    getdir: Option<unsafe extern "C" fn() -> c_int>,
    mknod: Option<unsafe extern "C" fn(*const c_char, libc::mode_t, libc::dev_t) -> c_int>,
    mkdir: Option<unsafe extern "C" fn(*const c_char, libc::mode_t) -> c_int>,
    unlink: Option<unsafe extern "C" fn(*const c_char) -> c_int>,
    rmdir: Option<unsafe extern "C" fn(*const c_char) -> c_int>,
    symlink: Option<unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>,
    rename: Option<unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>,
    link: Option<unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>,
    chmod: Option<unsafe extern "C" fn(*const c_char, libc::mode_t) -> c_int>,
    chown: Option<unsafe extern "C" fn(*const c_char, libc::uid_t, libc::gid_t) -> c_int>,
    truncate: Option<unsafe extern "C" fn(*const c_char, libc::off_t) -> c_int>,
    utime: Option<unsafe extern "C" fn(*const c_char, *mut c_void) -> c_int>,
    open: Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo) -> c_int>,
    read: Option<
        unsafe extern "C" fn(
            *const c_char,
            *mut c_char,
            usize,
            libc::off_t,
            *mut FuseFileInfo,
        ) -> c_int,
    >,
    write: Option<
        unsafe extern "C" fn(
            *const c_char,
            *const c_char,
            usize,
            libc::off_t,
            *mut FuseFileInfo,
        ) -> c_int,
    >,
    statfs: Option<unsafe extern "C" fn(*const c_char, *mut c_void) -> c_int>,
    flush: Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo) -> c_int>,
    release: Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo) -> c_int>,
    fsync: Option<unsafe extern "C" fn(*const c_char, c_int, *mut FuseFileInfo) -> c_int>,
    setxattr: Option<
        unsafe extern "C" fn(
            *const c_char,
            *const c_char,
            *const c_char,
            usize,
            c_int,
            u32,
        ) -> c_int,
    >,
    getxattr: Option<
        unsafe extern "C" fn(*const c_char, *const c_char, *mut c_char, usize, u32) -> c_int,
    >,
    listxattr: Option<unsafe extern "C" fn(*const c_char, *mut c_char, usize) -> c_int>,
    removexattr: Option<unsafe extern "C" fn(*const c_char, *const c_char) -> c_int>,
    opendir: Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo) -> c_int>,
    readdir: Option<
        unsafe extern "C" fn(
            *const c_char,
            *mut c_void,
            FuseFillDir,
            libc::off_t,
            *mut FuseFileInfo,
        ) -> c_int,
    >,
    releasedir: Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo) -> c_int>,
    fsyncdir: Option<unsafe extern "C" fn(*const c_char, c_int, *mut FuseFileInfo) -> c_int>,
    init: Option<unsafe extern "C" fn(*mut c_void) -> *mut c_void>,
    destroy: Option<unsafe extern "C" fn(*mut c_void)>,
    access: Option<unsafe extern "C" fn(*const c_char, c_int) -> c_int>,
    create: Option<unsafe extern "C" fn(*const c_char, libc::mode_t, *mut FuseFileInfo) -> c_int>,
    ftruncate: Option<unsafe extern "C" fn(*const c_char, libc::off_t, *mut FuseFileInfo) -> c_int>,
    fgetattr:
        Option<unsafe extern "C" fn(*const c_char, *mut libc::stat, *mut FuseFileInfo) -> c_int>,
    lock:
        Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo, c_int, *mut c_void) -> c_int>,
    utimens: Option<unsafe extern "C" fn(*const c_char, *const libc::timespec) -> c_int>,
    bmap: Option<unsafe extern "C" fn(*const c_char, usize, *mut u64) -> c_int>,
    flags: c_uint,
    ioctl: Option<
        unsafe extern "C" fn(
            *const c_char,
            c_int,
            *mut c_void,
            *mut FuseFileInfo,
            c_uint,
            *mut c_void,
        ) -> c_int,
    >,
    poll: Option<
        unsafe extern "C" fn(*const c_char, *mut FuseFileInfo, *mut c_void, *mut c_uint) -> c_int,
    >,
    write_buf: Option<
        unsafe extern "C" fn(*const c_char, *mut c_void, libc::off_t, *mut FuseFileInfo) -> c_int,
    >,
    read_buf: Option<
        unsafe extern "C" fn(
            *const c_char,
            *mut *mut c_void,
            usize,
            libc::off_t,
            *mut FuseFileInfo,
        ) -> c_int,
    >,
    flock: Option<unsafe extern "C" fn(*const c_char, *mut FuseFileInfo, c_int) -> c_int>,
    fallocate: Option<
        unsafe extern "C" fn(
            *const c_char,
            c_int,
            libc::off_t,
            libc::off_t,
            *mut FuseFileInfo,
        ) -> c_int,
    >,
    reserved00: Option<
        unsafe extern "C" fn(
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
            *mut c_void,
        ) -> c_int,
    >,
    monitor: Option<unsafe extern "C" fn(*const c_char, u32)>,
    renamex: Option<unsafe extern "C" fn(*const c_char, *const c_char, c_uint) -> c_int>,
    statfs_x: Option<unsafe extern "C" fn(*const c_char, *mut c_void) -> c_int>,
    setvolname: Option<unsafe extern "C" fn(*const c_char) -> c_int>,
    exchange: Option<unsafe extern "C" fn(*const c_char, *const c_char, c_ulong) -> c_int>,
    getxtimes: Option<
        unsafe extern "C" fn(*const c_char, *mut libc::timespec, *mut libc::timespec) -> c_int,
    >,
    setbkuptime: Option<unsafe extern "C" fn(*const c_char, *const libc::timespec) -> c_int>,
    setchgtime: Option<unsafe extern "C" fn(*const c_char, *const libc::timespec) -> c_int>,
    setcrtime: Option<unsafe extern "C" fn(*const c_char, *const libc::timespec) -> c_int>,
    chflags: Option<unsafe extern "C" fn(*const c_char, u32) -> c_int>,
    setattr_x: Option<unsafe extern "C" fn(*const c_char, *mut SetattrX) -> c_int>,
    fsetattr_x:
        Option<unsafe extern "C" fn(*const c_char, *mut SetattrX, *mut FuseFileInfo) -> c_int>,
}

#[repr(C)]
struct FuseFileInfo {
    flags: c_int,
    fh_old: c_ulong,
    writepage: c_int,
    bitfield: c_uint,
    fh: u64,
    lock_owner: u64,
}

#[repr(C)]
struct SetattrX {
    valid: i32,
    mode: libc::mode_t,
    uid: libc::uid_t,
    gid: libc::gid_t,
    size: libc::off_t,
    acctime: libc::timespec,
    modtime: libc::timespec,
    crtime: libc::timespec,
    chgtime: libc::timespec,
    bkuptime: libc::timespec,
    flags: u32,
}

#[repr(C)]
struct FuseContext {
    fuse: *mut c_void,
    uid: libc::uid_t,
    gid: libc::gid_t,
    pid: libc::pid_t,
    private_data: *mut c_void,
    umask: libc::mode_t,
}

unsafe extern "C" {
    fn fuse_main_real(
        argc: c_int,
        argv: *mut *mut c_char,
        op: *const FuseOperations,
        op_size: usize,
        user_data: *mut c_void,
    ) -> c_int;

    fn fuse_get_context() -> *mut FuseContext;
}

fn main() {
    if let Err(err) = run() {
        eprintln!("exfuse_port: {err}");
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let mount_point = mount_point_from_args()?;
    let _ = PORT.set(Port::new());
    PORT.get().expect("port initialized").start_reader();

    // `fuse_main_real` below blocks this thread in the libfuse session loop, which
    // only wakes for KERNEL filesystem ops — never for the BEAM's death. So a hard
    // BEAM exit (crash / `kill -9`) would otherwise leave this process parked here,
    // holding the mount forever (an orphaned `exfuse_port@macfuse0`). Watch for it.
    spawn_parent_death_watchdog(mount_point.clone());

    let mut args = [
        CString::new("exfuse_port").unwrap(),
        CString::new("-f").unwrap(),
        CString::new(mount_point.to_string_lossy().as_bytes()).unwrap(),
    ];
    let mut argv: Vec<*mut c_char> = args
        .iter_mut()
        .map(|arg| arg.as_ptr() as *mut c_char)
        .collect();

    let ops = fuse_operations();
    let result = unsafe {
        fuse_main_real(
            argv.len() as c_int,
            argv.as_mut_ptr(),
            &ops,
            mem::size_of::<FuseOperations>(),
            ptr::null_mut(),
        )
    };

    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(result.abs()))
    }
}

/// How often the watchdog checks whether the owning BEAM is still our parent.
const PARENT_WATCH_INTERVAL: Duration = Duration::from_millis(1000);

/// We are orphaned once our parent pid changes: when the BEAM (our spawner,
/// `erl_child_setup`) dies, the kernel reparents us to launchd/init or a
/// subreaper, so any pid other than the one we started under means the owner
/// is gone.
fn orphaned(original_ppid: i32, current_ppid: i32) -> bool {
    current_ppid != original_ppid
}

/// Block, polling `current_ppid()` every `interval`, until [`orphaned`] is true,
/// then run `on_orphan`. Pure (it performs no syscalls itself) so the loop can be
/// driven deterministically in tests.
fn watch_parent(
    original: i32,
    mut current_ppid: impl FnMut() -> i32,
    on_orphan: impl FnOnce(),
    interval: Duration,
) {
    while !orphaned(original, current_ppid()) {
        thread::sleep(interval);
    }
    on_orphan();
}

/// Spawn the parent-death watchdog. On the BEAM's death it tears the mount down so
/// the mount never outlives its owner.
fn spawn_parent_death_watchdog(mount_point: PathBuf) {
    let original = unsafe { libc::getppid() };
    thread::spawn(move || {
        watch_parent(
            original,
            || unsafe { libc::getppid() },
            || teardown(&mount_point),
            PARENT_WATCH_INTERVAL,
        );
    });
}

/// Best-effort force-unmount, then exit. Exiting closes our `/dev/macfuse` fd,
/// which the kernel treats as the unmount signal; the explicit unmount first
/// covers the case where the kernel would otherwise leave a dead mount behind.
fn teardown(mount_point: &Path) -> ! {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        if let Ok(path) = CString::new(mount_point.as_os_str().as_bytes()) {
            unsafe { libc::unmount(path.as_ptr(), libc::MNT_FORCE) };
        }
    }
    let _ = mount_point;
    std::process::exit(0);
}

fn mount_point_from_args() -> io::Result<PathBuf> {
    let mut args = env::args_os().skip(1);

    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--mount-point" | "-m" | "-f") => {
                if let Some(path) = args.next() {
                    return Ok(PathBuf::from(path));
                }
            }
            _ if !arg.as_encoded_bytes().starts_with(b"-") => return Ok(PathBuf::from(arg)),
            _ => {}
        }
    }

    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        "missing --mount-point",
    ))
}

fn fuse_operations() -> FuseOperations {
    unsafe { mem::zeroed::<FuseOperations>() }.with_callbacks()
}

trait WithCallbacks {
    fn with_callbacks(self) -> Self;
}

impl WithCallbacks for FuseOperations {
    fn with_callbacks(mut self) -> Self {
        self.getattr = Some(fuse_getattr);
        self.readlink = Some(fuse_readlink);
        self.mkdir = Some(fuse_mkdir);
        self.unlink = Some(fuse_unlink);
        self.rmdir = Some(fuse_rmdir);
        self.rename = Some(fuse_rename);
        self.chmod = Some(fuse_chmod);
        self.chown = Some(fuse_chown);
        self.truncate = Some(fuse_truncate);
        self.open = Some(fuse_open);
        self.read = Some(fuse_read);
        self.write = Some(fuse_write);
        self.flush = Some(fuse_flush);
        self.release = Some(fuse_release);
        self.fsync = Some(fuse_fsync);
        self.opendir = Some(fuse_opendir);
        self.readdir = Some(fuse_readdir);
        self.init = Some(fuse_init);
        self.create = Some(fuse_create);
        self.ftruncate = Some(fuse_ftruncate);
        self.renamex = Some(fuse_renamex);
        self.ioctl = Some(fuse_ioctl);
        self.setattr_x = Some(fuse_setattr_x);
        self.fsetattr_x = Some(fuse_fsetattr_x);
        self
    }
}

unsafe extern "C" fn fuse_init(_conn: *mut c_void) -> *mut c_void {
    if let Some(port) = PORT.get() {
        let _ = port.send_status();
    }

    ptr::null_mut()
}

unsafe extern "C" fn fuse_getattr(path: *const c_char, stat: *mut libc::stat) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.getattr(path)) {
        Ok(attr) => {
            unsafe {
                ptr::write_bytes(stat, 0, 1);
                (*stat).st_mode = attr.mode;
                (*stat).st_nlink = attr.nlink;
                (*stat).st_size = attr.size;
                (*stat).st_uid = libc::getuid();
                (*stat).st_gid = libc::getgid();
                (*stat).st_blocks = (attr.size + 511) / 512;
                if let Some(mtime) = attr.mtime {
                    (*stat).st_mtime = mtime;
                    (*stat).st_ctime = mtime;
                }
            }
            0
        }
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_readlink(path: *const c_char, buf: *mut c_char, size: usize) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.readlink(path)) {
        Ok(target) => {
            if size == 0 {
                return 0;
            }

            let bytes = target.as_bytes();
            let len = min(bytes.len(), size - 1);
            unsafe {
                ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, len);
                *buf.add(len) = 0;
            }
            0
        }
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_mkdir(path: *const c_char, mode: libc::mode_t) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.mkdir(path, mode)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_unlink(path: *const c_char) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.unlink(path)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_rmdir(path: *const c_char) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.rmdir(path)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_rename(from: *const c_char, to: *const c_char) -> c_int {
    rename_paths(from, to, 0)
}

unsafe extern "C" fn fuse_renamex(from: *const c_char, to: *const c_char, flags: c_uint) -> c_int {
    rename_paths(from, to, flags)
}

fn rename_paths(from: *const c_char, to: *const c_char, flags: c_uint) -> c_int {
    let Some(from) = path_to_str(from) else {
        return -libc::EINVAL;
    };
    let Some(to) = path_to_str(to) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.rename(from, to, flags)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_chmod(path: *const c_char, mode: libc::mode_t) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.chmod(path, mode)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_chown(path: *const c_char, uid: libc::uid_t, gid: libc::gid_t) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.chown(path, uid, gid)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_truncate(path: *const c_char, size: libc::off_t) -> c_int {
    truncate_path(path, size)
}

unsafe extern "C" fn fuse_ftruncate(
    path: *const c_char,
    size: libc::off_t,
    _fi: *mut FuseFileInfo,
) -> c_int {
    truncate_path(path, size)
}

fn truncate_path(path: *const c_char, size: libc::off_t) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    if size < 0 {
        return -libc::EINVAL;
    }

    match with_port(|port| port.truncate(path, size as u64)) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_open(path: *const c_char, fi: *mut FuseFileInfo) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.open(path, file_flags(fi))) {
        Ok(handle) => {
            set_file_handle(fi, handle);
            0
        }
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_create(
    path: *const c_char,
    mode: libc::mode_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.create(path, mode, file_flags(fi))) {
        Ok(handle) => {
            set_file_handle(fi, handle);
            0
        }
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_opendir(_path: *const c_char, _fi: *mut FuseFileInfo) -> c_int {
    0
}

unsafe extern "C" fn fuse_read(
    path: *const c_char,
    buf: *mut c_char,
    size: usize,
    offset: libc::off_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| {
        port.read(
            path,
            file_flags(fi),
            file_handle(fi),
            offset.max(0) as u64,
            size as u64,
        )
    }) {
        Ok(data) => {
            let len = min(size, data.len());
            let chunk = &data[..len];
            unsafe {
                ptr::copy_nonoverlapping(chunk.as_ptr(), buf as *mut u8, chunk.len());
            }
            chunk.len() as c_int
        }
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_write(
    path: *const c_char,
    buf: *const c_char,
    size: usize,
    offset: libc::off_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    let data = unsafe { std::slice::from_raw_parts(buf as *const u8, size) };

    match with_port(|port| port.write(path, file_handle(fi), offset.max(0) as u64, data)) {
        Ok(written) => written as c_int,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_readdir(
    path: *const c_char,
    buf: *mut c_void,
    filler: FuseFillDir,
    offset: libc::off_t,
    _fi: *mut FuseFileInfo,
) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };
    let Some(filler) = filler else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.readdir(path)) {
        Ok(entries) => {
            let start = offset.max(0) as usize;

            for (index, entry) in [".", ".."]
                .iter()
                .copied()
                .chain(entries.iter().map(String::as_str))
                .enumerate()
                .skip(start)
            {
                if let Ok(name) = CString::new(entry) {
                    let next_offset = (index + 1) as libc::off_t;
                    unsafe {
                        if filler(buf, name.as_ptr(), ptr::null(), next_offset) != 0 {
                            break;
                        }
                    }
                }
            }

            0
        }
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_flush(path: *const c_char, fi: *mut FuseFileInfo) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.flush(path, file_flags(fi), file_handle(fi))) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_release(path: *const c_char, fi: *mut FuseFileInfo) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.release(path, file_flags(fi), file_handle(fi))) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_fsync(
    path: *const c_char,
    datasync: c_int,
    fi: *mut FuseFileInfo,
) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.fsync(path, datasync != 0, file_flags(fi), file_handle(fi))) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_ioctl(
    path: *const c_char,
    _cmd: c_int,
    _arg: *mut c_void,
    fi: *mut FuseFileInfo,
    flags: c_uint,
    _data: *mut c_void,
) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    match with_port(|port| port.fsync(path, false, flags, file_handle(fi))) {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

unsafe extern "C" fn fuse_setattr_x(path: *const c_char, attr: *mut SetattrX) -> c_int {
    setattr_path(path, attr)
}

unsafe extern "C" fn fuse_fsetattr_x(
    path: *const c_char,
    attr: *mut SetattrX,
    _fi: *mut FuseFileInfo,
) -> c_int {
    setattr_path(path, attr)
}

fn setattr_path(path: *const c_char, attr: *mut SetattrX) -> c_int {
    let Some(path) = path_to_str(path) else {
        return -libc::EINVAL;
    };

    if attr.is_null() {
        return -libc::EINVAL;
    }

    let attr = unsafe { &*attr };

    if attr.valid & SETATTR_SIZE != 0 && attr.size < 0 {
        return -libc::EINVAL;
    }

    let result = with_port(|port| {
        if attr.valid & SETATTR_SIZE != 0 {
            port.truncate(path, attr.size as u64)?;
        }

        if attr.valid & SETATTR_MODE != 0 {
            port.chmod(path, attr.mode)?;
        }

        if attr.valid & (SETATTR_UID | SETATTR_GID) != 0 {
            let uid = if attr.valid & SETATTR_UID != 0 {
                attr.uid
            } else {
                u32::MAX as libc::uid_t
            };
            let gid = if attr.valid & SETATTR_GID != 0 {
                attr.gid
            } else {
                u32::MAX as libc::gid_t
            };
            port.chown(path, uid, gid)?;
        }

        Ok(())
    });

    match result {
        Ok(()) => 0,
        Err(errno) => -errno,
    }
}

fn with_port<T>(fun: impl FnOnce(&Port) -> Result<T, c_int>) -> Result<T, c_int> {
    let port = PORT.get().ok_or(libc::EIO)?;
    fun(port)
}

fn path_to_str<'a>(path: *const c_char) -> Option<&'a str> {
    if path.is_null() {
        return None;
    }

    unsafe { CStr::from_ptr(path) }.to_str().ok()
}

fn file_flags(fi: *mut FuseFileInfo) -> u32 {
    if fi.is_null() {
        0
    } else {
        unsafe { (*fi).flags as u32 }
    }
}

fn file_handle(fi: *mut FuseFileInfo) -> u64 {
    if fi.is_null() { 0 } else { unsafe { (*fi).fh } }
}

fn set_file_handle(fi: *mut FuseFileInfo, handle: Option<u64>) {
    if let (false, Some(handle)) = (fi.is_null(), handle) {
        unsafe {
            (*fi).fh = handle;
            (*fi).bitfield |= 1;
        }
    }
}

struct Attr {
    mode: libc::mode_t,
    nlink: libc::nlink_t,
    size: libc::off_t,
    mtime: Option<i64>,
}

struct RequestContext {
    uid: u32,
    gid: u32,
    pid: u32,
    umask: u32,
}

impl RequestContext {
    fn current() -> Self {
        let ctx = unsafe { fuse_get_context() };

        if ctx.is_null() {
            return Self {
                uid: 0,
                gid: 0,
                pid: 0,
                umask: 0,
            };
        }

        let ctx = unsafe { &*ctx };

        Self {
            uid: ctx.uid as u32,
            gid: ctx.gid as u32,
            pid: ctx.pid as u32,
            umask: mode_bits(ctx.umask),
        }
    }

    fn write_to(&self, packet: &mut Vec<u8>) {
        packet.extend_from_slice(&self.uid.to_be_bytes());
        packet.extend_from_slice(&self.gid.to_be_bytes());
        packet.extend_from_slice(&self.pid.to_be_bytes());
        packet.extend_from_slice(&self.umask.to_be_bytes());
    }
}

struct Port {
    output: Mutex<io::Stdout>,
    pending: Mutex<HashMap<u64, mpsc::Sender<Vec<u8>>>>,
    next_request_id: AtomicU64,
}

impl Port {
    fn new() -> Self {
        Self {
            output: Mutex::new(io::stdout()),
            pending: Mutex::new(HashMap::new()),
            next_request_id: AtomicU64::new(1),
        }
    }

    fn start_reader(&'static self) {
        thread::spawn(move || {
            let mut input = io::stdin();
            while let Ok(response) = read_packet(&mut input) {
                if response.len() < 24
                    || read_u32(&response[0..4]) != MAGIC
                    || read_u32(&response[4..8]) != PROTOCOL_V2
                {
                    continue;
                }
                let request_id = read_u64(&response[12..20]);
                if let Ok(mut pending) = self.pending.lock() {
                    if let Some(sender) = pending.remove(&request_id) {
                        let _ = sender.send(response);
                    }
                }
            }
            if let Ok(mut pending) = self.pending.lock() {
                pending.clear();
            }
        });
    }

    fn send_status(&self) -> io::Result<()> {
        let mut payload = Vec::with_capacity(12);
        payload.extend_from_slice(&MAGIC.to_be_bytes());
        payload.extend_from_slice(&Message::Status.code().to_be_bytes());
        payload.extend_from_slice(&std::process::id().to_be_bytes());

        self.write_packet(&payload)
    }

    fn getattr(&self, path: &str) -> Result<Attr, c_int> {
        let response = self.request(Message::Getattr, path.as_bytes())?;
        let data = response.ok()?;

        if data.len() != 12 && data.len() != 20 {
            return Err(libc::EIO);
        }

        let mode = read_u32(&data[0..4]);
        let kind = NodeKind::from_wire(read_u32(&data[4..8])).ok_or(libc::EIO)?;
        let kind_mode = kind.fuse_mode();
        let size = read_u32(&data[8..12]) as libc::off_t;

        // Extended attr form: a trailing u64 mtime lets content-projection
        // filesystems signal content changes for kernel cache revalidation.
        let mtime = if data.len() == 20 {
            let mut raw = [0u8; 8];
            raw.copy_from_slice(&data[12..20]);
            Some(i64::from_be_bytes(raw))
        } else {
            None
        };

        Ok(Attr {
            mode: kind_mode | ((mode & 0o7777) as libc::mode_t),
            nlink: if matches!(kind, NodeKind::Dir) { 2 } else { 1 },
            size,
            mtime,
        })
    }

    fn readdir(&self, path: &str) -> Result<Vec<String>, c_int> {
        let response = self.request(Message::Readdir, path.as_bytes())?;
        let data = response.ok()?;

        Ok(data
            .split(|byte| *byte == 0)
            .filter(|entry| !entry.is_empty())
            .map(|entry| String::from_utf8_lossy(entry).into_owned())
            .collect())
    }

    fn readlink(&self, path: &str) -> Result<String, c_int> {
        let response = self.request(Message::Readlink, path.as_bytes())?;
        let mut data = response.ok()?;

        if data.last() == Some(&0) {
            data.pop();
        }

        Ok(String::from_utf8_lossy(&data).into_owned())
    }

    fn read(
        &self,
        path: &str,
        flags: u32,
        handle: u64,
        offset: u64,
        size: u64,
    ) -> Result<Vec<u8>, c_int> {
        let mut payload = Vec::with_capacity(28 + path.len());
        payload.extend_from_slice(&flags.to_be_bytes());
        payload.extend_from_slice(&handle.to_be_bytes());
        payload.extend_from_slice(&offset.to_be_bytes());
        payload.extend_from_slice(&size.to_be_bytes());
        payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
        payload.extend_from_slice(path.as_bytes());

        let response = self.request(Message::Read, &payload)?;
        response.ok()
    }

    fn write(&self, path: &str, handle: u64, offset: u64, data: &[u8]) -> Result<u32, c_int> {
        let mut payload = Vec::with_capacity(16 + 4 + path.len() + data.len());
        payload.extend_from_slice(&handle.to_be_bytes());
        payload.extend_from_slice(&offset.to_be_bytes());
        payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
        payload.extend_from_slice(path.as_bytes());
        payload.extend_from_slice(data);

        let response = self.request(Message::Write, &payload)?;
        let data = response.ok()?;

        if data.len() != 4 {
            return Err(libc::EIO);
        }

        Ok(read_u32(&data[0..4]))
    }

    fn open(&self, path: &str, flags: u32) -> Result<Option<u64>, c_int> {
        let response = self.request(Message::Open, &path_flags_payload(path, flags))?;
        open_handle(response)
    }

    fn create(&self, path: &str, mode: libc::mode_t, flags: u32) -> Result<Option<u64>, c_int> {
        let mut payload = Vec::with_capacity(12 + path.len());
        payload.extend_from_slice(&mode_bits(mode).to_be_bytes());
        payload.extend_from_slice(&flags.to_be_bytes());
        payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
        payload.extend_from_slice(path.as_bytes());

        let response = self.request(Message::Create, &payload)?;
        open_handle(response)
    }

    fn truncate(&self, path: &str, size: u64) -> Result<(), c_int> {
        let response = self.request(Message::Truncate, &path_u64_payload(path, size))?;
        response.empty()
    }

    fn unlink(&self, path: &str) -> Result<(), c_int> {
        let response = self.request(Message::Unlink, path.as_bytes())?;
        response.empty()
    }

    fn rename(&self, from: &str, to: &str, flags: c_uint) -> Result<(), c_int> {
        let mut payload = Vec::with_capacity(12 + from.len() + to.len());
        payload.extend_from_slice(&flags.to_be_bytes());
        payload.extend_from_slice(&(from.len() as u32).to_be_bytes());
        payload.extend_from_slice(from.as_bytes());
        payload.extend_from_slice(&(to.len() as u32).to_be_bytes());
        payload.extend_from_slice(to.as_bytes());

        let response = self.request(Message::Rename, &payload)?;
        response.empty()
    }

    fn mkdir(&self, path: &str, mode: libc::mode_t) -> Result<(), c_int> {
        let response = self.request(Message::Mkdir, &path_u32_payload(path, mode_bits(mode)))?;
        response.empty()
    }

    fn rmdir(&self, path: &str) -> Result<(), c_int> {
        let response = self.request(Message::Rmdir, path.as_bytes())?;
        response.empty()
    }

    fn chmod(&self, path: &str, mode: libc::mode_t) -> Result<(), c_int> {
        let response = self.request(Message::Chmod, &path_u32_payload(path, mode_bits(mode)))?;
        response.empty()
    }

    fn chown(&self, path: &str, uid: libc::uid_t, gid: libc::gid_t) -> Result<(), c_int> {
        let mut payload = Vec::with_capacity(12 + path.len());
        payload.extend_from_slice(&uid.to_be_bytes());
        payload.extend_from_slice(&gid.to_be_bytes());
        payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
        payload.extend_from_slice(path.as_bytes());

        let response = self.request(Message::Chown, &payload)?;
        response.empty()
    }

    fn flush(&self, path: &str, flags: u32, handle: u64) -> Result<(), c_int> {
        let response = self.request(Message::Flush, &path_handle_payload(path, flags, handle))?;
        response.empty()
    }

    fn release(&self, path: &str, flags: u32, handle: u64) -> Result<(), c_int> {
        let response = self.request(Message::Release, &path_handle_payload(path, flags, handle))?;
        response.empty()
    }

    fn fsync(&self, path: &str, datasync: bool, flags: u32, handle: u64) -> Result<(), c_int> {
        let mut payload = Vec::with_capacity(20 + path.len());
        payload.extend_from_slice(&(datasync as u32).to_be_bytes());
        payload.extend_from_slice(&flags.to_be_bytes());
        payload.extend_from_slice(&handle.to_be_bytes());
        payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
        payload.extend_from_slice(path.as_bytes());

        let response = self.request(Message::Fsync, &payload)?;
        response.empty()
    }

    fn request(&self, message: Message, payload: &[u8]) -> Result<PortResponse, c_int> {
        let code = message.code();
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let mut packet = Vec::with_capacity(32 + payload.len());
        packet.extend_from_slice(&MAGIC.to_be_bytes());
        packet.extend_from_slice(&PROTOCOL_V2.to_be_bytes());
        packet.extend_from_slice(&code.to_be_bytes());
        packet.extend_from_slice(&request_id.to_be_bytes());
        RequestContext::current().write_to(&mut packet);
        packet.extend_from_slice(payload);

        let (sender, receiver) = mpsc::channel();
        self.pending
            .lock()
            .map_err(|_| libc::EIO)?
            .insert(request_id, sender);
        if self.write_packet(&packet).is_err() {
            if let Ok(mut pending) = self.pending.lock() {
                pending.remove(&request_id);
            }
            return Err(libc::EIO);
        }
        let response = receiver.recv().map_err(|_| libc::EIO)?;

        if response.len() < 24 {
            return Err(libc::EIO);
        }

        if read_u32(&response[0..4]) != MAGIC
            || read_u32(&response[4..8]) != PROTOCOL_V2
            || read_u32(&response[8..12]) != code
            || read_u64(&response[12..20]) != request_id
        {
            return Err(libc::EIO);
        }

        Ok(PortResponse {
            error: read_u32(&response[20..24]),
            data: response[24..].to_vec(),
        })
    }

    fn write_packet(&self, payload: &[u8]) -> io::Result<()> {
        let mut output = self
            .output
            .lock()
            .map_err(|_| io::Error::other("output lock poisoned"))?;
        output.write_all(&(payload.len() as u32).to_be_bytes())?;
        output.write_all(payload)?;
        output.flush()
    }
}

struct PortResponse {
    error: u32,
    data: Vec<u8>,
}

impl PortResponse {
    fn ok(self) -> Result<Vec<u8>, c_int> {
        match self.error {
            0 => Ok(self.data),
            error => Err(errno(error)),
        }
    }

    fn empty(self) -> Result<(), c_int> {
        let data = self.ok()?;

        if data.is_empty() {
            Ok(())
        } else {
            Err(libc::EIO)
        }
    }
}

fn open_handle(response: PortResponse) -> Result<Option<u64>, c_int> {
    let data = response.ok()?;

    match data.len() {
        0 => Ok(None),
        8 => Ok(Some(read_u64(&data[0..8]))),
        _ => Err(libc::EIO),
    }
}

fn path_u32_payload(path: &str, value: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(8 + path.len());
    payload.extend_from_slice(&value.to_be_bytes());
    payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
    payload.extend_from_slice(path.as_bytes());
    payload
}

fn path_u64_payload(path: &str, value: u64) -> Vec<u8> {
    let mut payload = Vec::with_capacity(12 + path.len());
    payload.extend_from_slice(&value.to_be_bytes());
    payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
    payload.extend_from_slice(path.as_bytes());
    payload
}

fn path_flags_payload(path: &str, flags: u32) -> Vec<u8> {
    path_u32_payload(path, flags)
}

fn path_handle_payload(path: &str, flags: u32, handle: u64) -> Vec<u8> {
    let mut payload = Vec::with_capacity(16 + path.len());
    payload.extend_from_slice(&flags.to_be_bytes());
    payload.extend_from_slice(&handle.to_be_bytes());
    payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
    payload.extend_from_slice(path.as_bytes());
    payload
}

fn mode_bits(mode: libc::mode_t) -> u32 {
    (mode as u32) & 0o7777
}

fn read_packet(input: &mut io::Stdin) -> io::Result<Vec<u8>> {
    let mut size = [0u8; 4];
    input.read_exact(&mut size)?;

    let size = u32::from_be_bytes(size) as usize;
    let mut payload = vec![0; size];
    input.read_exact(&mut payload)?;

    Ok(payload)
}

fn read_u32(bytes: &[u8]) -> u32 {
    u32::from_be_bytes(bytes.try_into().expect("slice is exactly 4 bytes"))
}

fn read_u64(bytes: &[u8]) -> u64 {
    u64::from_be_bytes(bytes.try_into().expect("slice is exactly 8 bytes"))
}

fn errno(code: u32) -> c_int {
    match code {
        1 => libc::EPERM,
        2 => libc::ENOENT,
        5 => libc::EIO,
        13 => libc::EACCES,
        17 => libc::EEXIST,
        20 => libc::ENOTDIR,
        21 => libc::EISDIR,
        22 => libc::EINVAL,
        28 => libc::ENOSPC,
        30 => libc::EROFS,
        38 | 78 => libc::ENOSYS,
        _ => libc::EIO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn orphaned_only_when_parent_pid_changes() {
        assert!(!orphaned(2078, 2078));
        assert!(orphaned(2078, 1)); // reparented to launchd/init
        assert!(orphaned(2078, 4242)); // reparented to a subreaper
    }

    #[test]
    fn watch_parent_fires_once_the_owner_is_gone() {
        // Owner shows as pid 2078 for two polls, then the kernel reparents us to 1.
        let polls = Cell::new(0);
        let fired = Cell::new(false);

        watch_parent(
            2078,
            || {
                let n = polls.get();
                polls.set(n + 1);
                if n < 2 { 2078 } else { 1 }
            },
            || fired.set(true),
            Duration::ZERO,
        );

        assert!(fired.get(), "teardown must run after the owner dies");
        assert_eq!(
            polls.get(),
            3,
            "two matching polls, then the reparented one"
        );
    }

    #[test]
    fn watch_parent_does_not_fire_while_owner_lives() {
        // If the owner never changes, the loop keeps polling and never tears down.
        let polls = Cell::new(0);
        let fired = Cell::new(false);

        watch_parent(
            2078,
            || {
                polls.set(polls.get() + 1);
                if polls.get() >= 5 {
                    return 1; // end the test by simulating death on the 5th poll
                }
                2078
            },
            || fired.set(true),
            Duration::ZERO,
        );

        assert!(fired.get());
        assert_eq!(
            polls.get(),
            5,
            "stayed alive across the first four matching polls"
        );
    }
}
