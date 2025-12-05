/**
 * MAGNETO V4 - Matrix Rain Background Effect
 * Creates the iconic falling green characters effect
 */

class MatrixRain {
    constructor(canvasId) {
        this.canvas = document.getElementById(canvasId);
        this.ctx = this.canvas.getContext('2d');

        // Matrix characters (Katakana + Latin + Numbers + Symbols)
        this.chars = 'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%^&*()';
        this.charArray = this.chars.split('');

        // Configuration
        this.fontSize = 14;
        this.columns = 0;
        this.drops = [];

        // Colors
        this.primaryColor = '#00ff41';
        this.fadeColor = 'rgba(10, 10, 10, 0.05)';

        // Animation
        this.animationId = null;
        this.lastTime = 0;
        this.frameInterval = 50; // ~20 FPS for performance

        // Initialize
        this.init();
        this.bindEvents();
    }

    init() {
        this.resize();
        this.initDrops();
    }

    resize() {
        this.canvas.width = window.innerWidth;
        this.canvas.height = window.innerHeight;
        this.columns = Math.floor(this.canvas.width / this.fontSize);

        // Reinitialize drops if columns changed
        if (this.drops.length !== this.columns) {
            this.initDrops();
        }
    }

    initDrops() {
        this.drops = [];
        for (let i = 0; i < this.columns; i++) {
            // Start at random positions
            this.drops[i] = {
                y: Math.random() * this.canvas.height / this.fontSize,
                speed: 0.5 + Math.random() * 0.5, // Variable speeds
                brightness: Math.random()
            };
        }
    }

    bindEvents() {
        window.addEventListener('resize', () => {
            this.resize();
        });

        // Pause when tab is not visible for performance
        document.addEventListener('visibilitychange', () => {
            if (document.hidden) {
                this.stop();
            } else {
                this.start();
            }
        });
    }

    draw(timestamp) {
        // Throttle frame rate
        if (timestamp - this.lastTime < this.frameInterval) {
            this.animationId = requestAnimationFrame((t) => this.draw(t));
            return;
        }
        this.lastTime = timestamp;

        // Semi-transparent black to create fade effect
        this.ctx.fillStyle = this.fadeColor;
        this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

        // Set font
        this.ctx.font = `${this.fontSize}px monospace`;

        // Draw characters
        for (let i = 0; i < this.drops.length; i++) {
            const drop = this.drops[i];

            // Random character
            const char = this.charArray[Math.floor(Math.random() * this.charArray.length)];

            // Calculate position
            const x = i * this.fontSize;
            const y = drop.y * this.fontSize;

            // Vary brightness for depth effect
            const alpha = 0.3 + drop.brightness * 0.7;
            this.ctx.fillStyle = `rgba(0, 255, 65, ${alpha})`;

            // Draw character
            this.ctx.fillText(char, x, y);

            // Occasionally draw a brighter "head" character
            if (Math.random() > 0.98) {
                this.ctx.fillStyle = '#ffffff';
                this.ctx.fillText(char, x, y);
            }

            // Move drop down
            drop.y += drop.speed;

            // Reset when reaching bottom (with some randomization)
            if (y > this.canvas.height && Math.random() > 0.975) {
                drop.y = 0;
                drop.speed = 0.5 + Math.random() * 0.5;
                drop.brightness = Math.random();
            }
        }

        this.animationId = requestAnimationFrame((t) => this.draw(t));
    }

    start() {
        if (!this.animationId) {
            this.animationId = requestAnimationFrame((t) => this.draw(t));
        }
    }

    stop() {
        if (this.animationId) {
            cancelAnimationFrame(this.animationId);
            this.animationId = null;
        }
    }
}

// Initialize Matrix Rain when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    const matrixRain = new MatrixRain('matrix-canvas');
    matrixRain.start();

    // Expose for debugging
    window.matrixRain = matrixRain;
});
