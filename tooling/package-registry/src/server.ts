import express, { Express, Request, Response, NextFunction } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import dotenv from 'dotenv';
import { MongoClient, Db } from 'mongodb';
import { createClient, RedisClientType } from 'redis';
import winston from 'winston';
import path from 'path';
import fs from 'fs';

// Routes
import { packageRouter } from './routes/packages';
import { userRouter } from './routes/users';
import { searchRouter } from './routes/search';
import { statsRouter } from './routes/stats';

dotenv.config();

const app: Express = express();
const PORT = process.env.PORT || 3000;

// Logger
export const logger = winston.createLogger({
    level: process.env.LOG_LEVEL || 'info',
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.json()
    ),
    transports: [
        new winston.transports.File({ filename: 'error.log', level: 'error' }),
        new winston.transports.File({ filename: 'combined.log' }),
        new winston.transports.Console({
            format: winston.format.simple()
        })
    ]
});

// Database connections
export let mongoDb: Db;
export let redisClient: RedisClientType;

// Middleware
app.use(helmet());
app.use(cors());
app.use(compression());
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true }));

// Request logging
app.use((req: Request, res: Response, next: NextFunction) => {
    logger.info(`${req.method} ${req.path}`, {
        ip: req.ip,
        userAgent: req.get('user-agent')
    });
    next();
});

// Static file serving for package tarballs
const STORAGE_PATH = process.env.STORAGE_PATH || path.join(__dirname, '../storage');
if (!fs.existsSync(STORAGE_PATH)) {
    fs.mkdirSync(STORAGE_PATH, { recursive: true });
}
app.use('/packages', express.static(STORAGE_PATH));

// API Routes
app.use('/api/packages', packageRouter);
app.use('/api/users', userRouter);
app.use('/api/search', searchRouter);
app.use('/api/stats', statsRouter);

// Health check
app.get('/health', (req: Request, res: Response) => {
    res.json({
        status: 'healthy',
        uptime: process.uptime(),
        timestamp: new Date().toISOString()
    });
});

// Root endpoint
app.get('/', (req: Request, res: Response) => {
    res.json({
        name: 'Ion Package Registry',
        version: '1.0.0',
        documentation: '/api/docs',
        endpoints: {
            packages: '/api/packages',
            search: '/api/search',
            users: '/api/users',
            stats: '/api/stats'
        }
    });
});

// Error handling
app.use((err: Error, req: Request, res: Response, next: NextFunction) => {
    logger.error('Unhandled error', {
        error: err.message,
        stack: err.stack,
        path: req.path
    });

    res.status(500).json({
        error: 'Internal server error',
        message: process.env.NODE_ENV === 'development' ? err.message : undefined
    });
});

// 404 handler
app.use((req: Request, res: Response) => {
    res.status(404).json({
        error: 'Not found',
        path: req.path
    });
});

// Initialize connections and start server
async function startServer() {
    try {
        // Connect to MongoDB
        const mongoUrl = process.env.MONGODB_URL || 'mongodb://localhost:27017';
        const client = new MongoClient(mongoUrl);
        await client.connect();
        mongoDb = client.db(process.env.DB_NAME || 'ion-registry');
        logger.info('Connected to MongoDB');

        // Create indexes
        await mongoDb.collection('packages').createIndex({ name: 1 }, { unique: true });
        await mongoDb.collection('packages').createIndex({ 'versions.version': 1 });
        await mongoDb.collection('packages').createIndex({ keywords: 1 });
        await mongoDb.collection('users').createIndex({ email: 1 }, { unique: true });
        await mongoDb.collection('users').createIndex({ username: 1 }, { unique: true });

        // Connect to Redis
        redisClient = createClient({
            url: process.env.REDIS_URL || 'redis://localhost:6379'
        });
        await redisClient.connect();
        logger.info('Connected to Redis');

        // Start server
        app.listen(PORT, () => {
            logger.info(`Ion Package Registry running on port ${PORT}`);
            logger.info(`Environment: ${process.env.NODE_ENV || 'development'}`);
        });

    } catch (error) {
        logger.error('Failed to start server', { error });
        process.exit(1);
    }
}

// Graceful shutdown
process.on('SIGTERM', async () => {
    logger.info('SIGTERM received, shutting down gracefully');
    if (redisClient) {
        await redisClient.quit();
    }
    process.exit(0);
});

startServer();

export default app;
