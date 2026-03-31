import 'package:flutter/material.dart';
import 'dart:math' as math;

class RecordingVisualizer extends StatefulWidget {
  final bool isRecording;

  const RecordingVisualizer({
    super.key,
    required this.isRecording,
  });

  @override
  State<RecordingVisualizer> createState() => _RecordingVisualizerState();
}

class _RecordingVisualizerState extends State<RecordingVisualizer>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    
    if (widget.isRecording) {
      _animationController.repeat();
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(RecordingVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording != oldWidget.isRecording) {
      if (widget.isRecording) {
        _animationController.repeat();
        _pulseController.repeat(reverse: true);
      } else {
        _animationController.stop();
        _pulseController.stop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Animated circles
          ...List.generate(12, (index) {
            return AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                final angle = (index * 30.0) * math.pi / 180;
                final animationValue = (_animationController.value + index * 0.08) % 1.0;
                final radius = 60 + (animationValue * 20);
                final opacity = widget.isRecording ? (1.0 - animationValue) * 0.8 : 0.3;
                
                return Positioned(
                  left: 100 + math.cos(angle) * radius - 4,
                  top: 100 + math.sin(angle) * radius - 4,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(
                        alpha: opacity,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              },
            );
          }),
          
          // Central microphone button
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final scale = 1.0 + (_pulseController.value * 0.1);
              return Transform.scale(
                scale: widget.isRecording ? scale : 1.0,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: widget.isRecording
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (widget.isRecording
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey)
                            .withValues(alpha: 0.3),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.pause,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }
}