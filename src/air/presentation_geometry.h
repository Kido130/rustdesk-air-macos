#pragma once

#include <cmath>

struct AirPresentationFit {
    double x = 1;
    double y = 1;
};

// The full-screen Air viewer uses the whole panel. Its GPU samples the source
// independently in X and Y, so every remote pixel remains visible even when
// the two built-in panels have slightly different aspect ratios.
inline AirPresentationFit air_presentation_fit(double sourceWidth,double sourceHeight,
    double drawableWidth,double drawableHeight,bool fullScreen,bool matchDisplay) {
    if (!(sourceWidth>0 && sourceHeight>0 && drawableWidth>0 && drawableHeight>0)) return {};
    if (fullScreen) return {};
    if (matchDisplay) return {sourceWidth/drawableWidth,sourceHeight/drawableHeight};
    double sourceAspect=sourceWidth/sourceHeight,drawableAspect=drawableWidth/drawableHeight;
    return sourceAspect>drawableAspect
        ? AirPresentationFit{1,drawableAspect/sourceAspect}
        : AirPresentationFit{sourceAspect/drawableAspect,1};
}

struct AirSourcePoint { double x=0,y=0; bool inside=false; };
inline AirSourcePoint air_presentation_source_point(double viewX,double viewY,
    double viewWidth,double viewHeight,double sourceWidth,double sourceHeight,AirPresentationFit fit) {
    if (!(viewWidth>0 && viewHeight>0 && sourceWidth>0 && sourceHeight>0 && fit.x>0 && fit.y>0)) return {};
    double width=viewWidth*fit.x,height=viewHeight*fit.y;
    double x=(viewX-(viewWidth-width)/2)*sourceWidth/width;
    double y=(viewHeight-viewY-(viewHeight-height)/2)*sourceHeight/height;
    return {x,y,std::isfinite(x)&&std::isfinite(y)&&x>=0&&y>=0&&x<sourceWidth&&y<sourceHeight};
}
