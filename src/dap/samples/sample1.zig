fn myadd(a: i32, b: i32) i32 {
    var sum: i32 = a + b;
    @breakpoint();
    sum += 1;
    @breakpoint();
    return sum;
}
pub fn main() void {
    const p = Point{ .x = 3, .y = 4 };
    var i: i32 = 0;
    @breakpoint();
    while (i < p.x) : (i += 1) {}
    _ = myadd(p.x, p.y);
}
const Point = struct { x: i32, y: i32 };
