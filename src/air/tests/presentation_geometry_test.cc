#include "../presentation_geometry.h"
#include <cassert>
#include <cmath>
#include <cstdio>

static bool near(double a,double b) { return std::abs(a-b)<.00001; }

int main() {
    // The actual Pro/Air aspect mismatch previously exposed side bars. Every
    // source edge now reaches its corresponding full-screen panel edge.
    auto full=air_presentation_fit(2294,1490,2560,1600,true,false);
    assert(near(full.x,1)&&near(full.y,1));
    auto left=air_presentation_source_point(0,800,1280,800,2294,1490,full);
    auto middle=air_presentation_source_point(640,400,1280,800,2294,1490,full);
    auto right=air_presentation_source_point(1279,400,1280,800,2294,1490,full);
    assert(left.inside&&near(left.x,0)&&near(left.y,0));
    assert(middle.inside&&near(middle.x,1147)&&near(middle.y,745));
    assert(right.inside&&right.x>2292);
    auto top=air_presentation_source_point(640,799,1280,800,2294,1490,full);
    assert(top.inside&&top.y<2);

    // Windowed presentation retains aspect fit and ignores letterbox clicks.
    auto windowed=air_presentation_fit(2294,1490,1600,1000,false,false);
    assert(windowed.x<1&&near(windowed.y,1));
    auto bar=air_presentation_source_point(0,500,800,500,2294,1490,windowed);
    assert(!bar.inside);
    auto center=air_presentation_source_point(400,250,800,500,2294,1490,windowed);
    assert(center.inside&&near(center.x,1147)&&near(center.y,745));

    // Windowed one-to-one mode still retains its existing crop semantics.
    auto oneToOne=air_presentation_fit(2294,1490,1600,1000,false,true);
    assert(near(oneToOne.x,2294.0/1600)&&near(oneToOne.y,1.49));
    puts("Air full-screen Metal geometry fills panel and maps pointer; windowed modes preserved");
}
