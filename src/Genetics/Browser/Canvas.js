"use strict";

exports.createCanvas = function(size) {
    return function(className) {
        return function() {
            var c = document.createElement('canvas');
            c.width  = size.width;
            c.height = size.height;
            c.className = className;
            return c;
        };
    };
};

exports.setElementStyleImpl = function(e,k,v) {
    e.style[k] = v;
}

exports.appendCanvasElem = function(cont) {
    return function(canv) {
        return function() {
            cont.appendChild(canv);
        };
    };
}

exports.setContainerStyle = function(e) {
    return function(dim) {
        return function() {
            e.style.position = "relative";
            e.style.border   = "1px solid black";
            e.style.display  = "block";
            e.style.margin   = "0";
            e.style.padding  = "0";
            e.style.width = (dim.width - 2) + "px"; // remove 2px for the border
            e.style.height = dim.height + "px";
        };
    };
};

exports.drawCopies = function(bfr, bfrDim, ctx, ps) {
    ps.forEach(function(p) {
        ctx.drawImage(bfr,
                      0, 0,
                      bfrDim.width, bfrDim.height,
                      p.x - (bfrDim.width  / 2.0),
                      p.y - (bfrDim.height / 2.0),
                      bfrDim.width, bfrDim.height);
    });
};

exports.setCanvasTranslation = function(p) {
    return function(c) {
        return function() {
            var ctx = c.getContext('2d');
            ctx.setTransform(1, 0, 0, 1, p.x, p.y);
        };
    };
};


exports.canvasClickImpl = function(canvas, cb) {
    var rect = canvas.getBoundingClientRect();
    canvas.addEventListener('mousedown', function(e) {
        var x = e.clientX - rect.left + window.scrollX;
        var y = e.clientY - rect.top  + window.scrollY;
        cb({x: x, y: y})();
    });
};


// scrolls a canvas, given a "back buffer" canvas to copy the current context to
exports.scrollCanvasImpl = function(backCanvas, canvas, p) {
    // for some reason, doing this in newCanvas() below doesn't stick
    backCanvas.width = canvas.width;
    backCanvas.height = canvas.height;

    var bCtx = backCanvas.getContext('2d');
    var ctx = canvas.getContext('2d');

    bCtx.drawImage(canvas, 0, 0);

    ctx.save();
    ctx.setTransform(1,0,0,1,0,0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(backCanvas, p.x, p.y);
    ctx.restore();
};



exports.canvasDragImpl = function(canvas) {
    return function(cb) {
        return function() {
            var cbInner = function(e) {
                var startX = e.clientX;
                var startY = e.clientY;
                var lastX = e.clientX;
                var lastY = e.clientY;

                var f = function(e2) {
                    cb({during: {x: lastX - e2.clientX, y: lastY - e2.clientY}})();
                    lastX = e2.clientX;
                    lastY = e2.clientY;
                };

                document.addEventListener('mousemove', f);

                document.addEventListener('mouseup', function(e2) {
                    document.removeEventListener('mousemove', f);
                    cb({total: {x: e2.clientX-startX, y: e2.clientY-startY}})();
                }, { once: true });
            };

            canvas.addEventListener('mousedown', cbInner);
            return function() {
                canvas.removeEventListener('mousedown', cbInner);
            }
        };
    };
};


exports.canvasWheelCBImpl = function(canvas) {
    return function(cb) {
        return function() {
            var evCb = function(e) {
                cb(Math.sign(e.deltaY))();
            };

            canvas.addEventListener("wheel", evCb);
        }
    };
};


exports.debugBrowserCanvas = function(k) {
    return function(bc) {
        return function() {
            window[k] = bc;
        };
    };
};