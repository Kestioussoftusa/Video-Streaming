// Final Codebase for Deployment

// Import Dependencies
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const multer = require('multer');
const Stripe = require('stripe');
const WebRTCAdaptor = require('@antmedia/webrtc_adaptor');
require('dotenv').config();

// Initialize Express App and Server
const app = express();
const server = http.createServer(app);
const io = new Server(server);

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static('public'));

// Multer Setup for File Uploads
const storage = multer.diskStorage({
  destination: 'uploads/',
  filename: (req, file, cb) => {
    cb(null, `${Date.now()}-${file.originalname}`);
  },
});
const upload = multer({ storage });

// Stripe Setup
const stripe = Stripe(process.env.STRIPE_SECRET_KEY);

// WebRTC Configuration
const rtcAdaptor = new WebRTCAdaptor({
  websocket_url: process.env.WEBRTC_URL,
  mediaConstraints: { video: true, audio: true },
  peerconnection_config: {
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
  },
});

// Peer-to-Peer Video Rooms
const rooms = {};

io.on('connection', (socket) => {
  console.log('User connected:', socket.id);

  socket.on('join-room', (roomId, userId) => {
    console.log(`User ${userId} joined room ${roomId}`);
    if (!rooms[roomId]) rooms[roomId] = [];
    rooms[roomId].push(userId);
    socket.join(roomId);
    socket.to(roomId).emit('user-connected', userId);

    socket.on('disconnect', () => {
      console.log(`User ${userId} disconnected from room ${roomId}`);
      rooms[roomId] = rooms[roomId].filter((id) => id !== userId);
      socket.to(roomId).emit('user-disconnected', userId);
    });
  });
});

// Admin Video Upload Endpoint
app.post('/upload', upload.single('video'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  res.status(200).json({
    message: 'Video uploaded successfully',
    path: `${req.protocol}://${req.get('host')}/uploads/${req.file.filename}`,
  });
});

// Stripe Payment Endpoints
app.post('/donate', async (req, res) => {
  const { amount, currency } = req.body;
  try {
    const paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency,
      payment_method_types: ['card'],
    });
    res.status(200).json({ clientSecret: paymentIntent.client_secret });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/subscribe', async (req, res) => {
  const { email, plan } = req.body;
  try {
    const customer = await stripe.customers.create({ email });
    const subscription = await stripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: plan }],
    });
    res.status(200).json({ subscription });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Start the Server
const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
});

// Frontend Integration (React)
// Ensure React frontend is built and served from the public directory.

