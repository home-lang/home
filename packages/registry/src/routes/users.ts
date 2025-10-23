import { Router, Request, Response } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { mongoDb, logger } from '../server';
import { authMiddleware } from '../middleware/auth';

export const userRouter = Router();

const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key';

// POST /api/users/register - Register a new user
userRouter.post('/register', async (req: Request, res: Response) => {
    try {
        const { username, email, password } = req.body;

        if (!username || !email || !password) {
            return res.status(400).json({
                error: 'Username, email, and password are required'
            });
        }

        // Check if user already exists
        const existingUser = await mongoDb.collection('users').findOne({
            $or: [{ email }, { username }]
        });

        if (existingUser) {
            return res.status(409).json({
                error: 'User already exists'
            });
        }

        // Hash password
        const hashedPassword = await bcrypt.hash(password, 10);

        // Create user
        const result = await mongoDb.collection('users').insertOne({
            username,
            email,
            password: hashedPassword,
            createdAt: new Date(),
            packages: []
        });

        logger.info('User registered', { username, email });

        res.status(201).json({
            message: 'User registered successfully',
            userId: result.insertedId
        });
    } catch (error) {
        logger.error('Error registering user', { error });
        res.status(500).json({ error: 'Failed to register user' });
    }
});

// POST /api/users/login - Login
userRouter.post('/login', async (req: Request, res: Response) => {
    try {
        const { email, password } = req.body;

        if (!email || !password) {
            return res.status(400).json({
                error: 'Email and password are required'
            });
        }

        // Find user
        const user = await mongoDb.collection('users').findOne({ email });

        if (!user) {
            return res.status(401).json({ error: 'Invalid credentials' });
        }

        // Verify password
        const validPassword = await bcrypt.compare(password, user.password);

        if (!validPassword) {
            return res.status(401).json({ error: 'Invalid credentials' });
        }

        // Generate token
        const token = jwt.sign(
            { userId: user._id, username: user.username },
            JWT_SECRET,
            { expiresIn: '7d' }
        );

        logger.info('User logged in', { username: user.username });

        res.json({
            token,
            user: {
                id: user._id,
                username: user.username,
                email: user.email
            }
        });
    } catch (error) {
        logger.error('Error logging in', { error });
        res.status(500).json({ error: 'Login failed' });
    }
});

// GET /api/users/me - Get current user
userRouter.get('/me', authMiddleware, async (req: Request, res: Response) => {
    try {
        const user = await mongoDb.collection('users').findOne(
            { _id: (req as any).user.userId },
            { projection: { password: 0 } }
        );

        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }

        res.json(user);
    } catch (error) {
        logger.error('Error fetching user', { error });
        res.status(500).json({ error: 'Failed to fetch user' });
    }
});

// GET /api/users/:username - Get user profile
userRouter.get('/:username', async (req: Request, res: Response) => {
    try {
        const { username } = req.params;

        const user = await mongoDb.collection('users').findOne(
            { username },
            { projection: { password: 0, email: 0 } }
        );

        if (!user) {
            return res.status(404).json({ error: 'User not found' });
        }

        // Get user's packages
        const packages = await mongoDb
            .collection('packages')
            .find({ publishedBy: username })
            .project({ name: 1, description: 1, latestVersion: 1, downloadCount: 1 })
            .toArray();

        res.json({
            ...user,
            packages
        });
    } catch (error) {
        logger.error('Error fetching user profile', { error, username: req.params.username });
        res.status(500).json({ error: 'Failed to fetch user profile' });
    }
});
