import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import path from "path";
import { createServer } from "http";
import { Server } from "socket.io";
// @ts-ignore
import { PrismaClient } from "./generated/client";

dotenv.config();

// Ensure DATABASE_URL is absolute to avoid relative path issues with generated client
// Point to the same DB file as Prisma CLI (relative to schema.prisma, usually in prisma/ folder)
const dbPath = path.resolve(__dirname, "../prisma/dev.db");
process.env.DATABASE_URL = `file:${dbPath}`;
console.log("Resolved DATABASE_URL:", process.env.DATABASE_URL);

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
  },
  maxHttpBufferSize: 1e8, // 100 MB
});
const prisma = new PrismaClient();
const PORT = process.env.PORT || 8000;

app.use(cors());
app.use(express.json({ limit: "50mb" }));

// Socket.io Logic
interface User {
  id: string;
  name: string;
  initials: string;
  color: string;
  socketId: string;
  isActive: boolean;
}

const roomUsers = new Map<string, User[]>();

io.on("connection", (socket) => {
  socket.on(
    "join-room",
    ({
      drawingId,
      user,
    }: {
      drawingId: string;
      user: Omit<User, "socketId" | "isActive">;
    }) => {
      const roomId = `drawing_${drawingId}`;
      socket.join(roomId);

      const newUser: User = { ...user, socketId: socket.id, isActive: true };

      const currentUsers = roomUsers.get(roomId) || [];
      const filteredUsers = currentUsers.filter((u) => u.id !== user.id);
      filteredUsers.push(newUser);
      roomUsers.set(roomId, filteredUsers);

      io.to(roomId).emit("presence-update", filteredUsers);
    }
  );

  socket.on("cursor-move", (data) => {
    const roomId = `drawing_${data.drawingId}`;
    // Use volatile for high-frequency, low-importance updates (cursors)
    // If network is congested, drop these packets
    socket.volatile.to(roomId).emit("cursor-move", data);
  });

  socket.on("element-update", (data) => {
    const roomId = `drawing_${data.drawingId}`;
    socket.to(roomId).emit("element-update", data);
  });

  socket.on(
    "user-activity",
    ({ drawingId, isActive }: { drawingId: string; isActive: boolean }) => {
      const roomId = `drawing_${drawingId}`;
      const users = roomUsers.get(roomId);
      if (users) {
        const user = users.find((u) => u.socketId === socket.id);
        if (user) {
          user.isActive = isActive;
          io.to(roomId).emit("presence-update", users);
        }
      }
    }
  );

  socket.on("disconnect", () => {
    roomUsers.forEach((users, roomId) => {
      const index = users.findIndex((u) => u.socketId === socket.id);
      if (index !== -1) {
        users.splice(index, 1);
        roomUsers.set(roomId, users);
        io.to(roomId).emit("presence-update", users);
      }
    });
  });
});

// --- Drawings ---

// GET /drawings
app.get("/drawings", async (req, res) => {
  try {
    const { search, collectionId } = req.query;
    const where: any = {};

    if (search) {
      where.name = { contains: String(search) };
    }

    if (collectionId === "null") {
      where.collectionId = null;
    } else if (collectionId) {
      where.collectionId = String(collectionId);
    } else {
      // Default: Exclude trash, but include unorganized (null)
      where.OR = [{ collectionId: { not: "trash" } }, { collectionId: null }];
    }

    const drawings = await prisma.drawing.findMany({
      where,
      orderBy: { updatedAt: "desc" },
    });

    // Parse JSON strings for response
    const parsedDrawings = drawings.map((d: any) => ({
      ...d,
      elements: JSON.parse(d.elements),
      appState: JSON.parse(d.appState),
    }));

    res.json(parsedDrawings);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Failed to fetch drawings" });
  }
});

// GET /drawings/:id
app.get("/drawings/:id", async (req, res) => {
  try {
    const { id } = req.params;
    console.log("[API] Fetching drawing", { id });
    const drawing = await prisma.drawing.findUnique({ where: { id } });

    if (!drawing) {
      console.warn("[API] Drawing not found", { id });
      return res.status(404).json({ error: "Drawing not found" });
    }

    console.log("[API] Returning drawing", {
      id,
      elementCount: (() => {
        try {
          const parsed = JSON.parse(drawing.elements);
          return Array.isArray(parsed) ? parsed.length : null;
        } catch (_err) {
          return null;
        }
      })(),
    });

    res.json({
      ...drawing,
      elements: JSON.parse(drawing.elements),
      appState: JSON.parse(drawing.appState),
    });
  } catch (error) {
    res.status(500).json({ error: "Failed to fetch drawing" });
  }
});

// POST /drawings
app.post("/drawings", async (req, res) => {
  try {
    const { name, elements, appState, collectionId, preview } = req.body;

    const newDrawing = await prisma.drawing.create({
      data: {
        name,
        elements: JSON.stringify(elements || []),
        appState: JSON.stringify(appState || {}),
        collectionId: collectionId || null,
        preview: preview || null,
      },
    });

    res.json({
      ...newDrawing,
      elements: JSON.parse(newDrawing.elements),
      appState: JSON.parse(newDrawing.appState),
    });
  } catch (error) {
    res.status(500).json({ error: "Failed to create drawing" });
  }
});

// PUT /drawings/:id
app.put("/drawings/:id", async (req, res) => {
  try {
    const { id } = req.params;
    const { name, elements, appState, collectionId, preview } = req.body;

    console.log("[API] Updating drawing", {
      id,
      hasElements: elements !== undefined,
      elementCount:
        elements && Array.isArray(elements) ? elements.length : undefined,
      hasAppState: appState !== undefined,
      hasPreview: preview !== undefined,
    });

    const data: any = {
      version: { increment: 1 },
    };

    if (name !== undefined) data.name = name;
    if (elements !== undefined) data.elements = JSON.stringify(elements);
    if (appState !== undefined) data.appState = JSON.stringify(appState);
    if (collectionId !== undefined) data.collectionId = collectionId;
    if (preview !== undefined) data.preview = preview;

    const updatedDrawing = await prisma.drawing.update({
      where: { id },
      data,
    });

    console.log("[API] Update complete", {
      id,
      storedElementCount: (() => {
        try {
          const parsed = JSON.parse(updatedDrawing.elements);
          return Array.isArray(parsed) ? parsed.length : null;
        } catch (_err) {
          return null;
        }
      })(),
    });

    res.json({
      ...updatedDrawing,
      elements: JSON.parse(updatedDrawing.elements),
      appState: JSON.parse(updatedDrawing.appState),
    });
  } catch (error) {
    res.status(500).json({ error: "Failed to update drawing" });
  }
});

// DELETE /drawings/:id
app.delete("/drawings/:id", async (req, res) => {
  try {
    const { id } = req.params;
    await prisma.drawing.delete({ where: { id } });
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: "Failed to delete drawing" });
  }
});

// POST /drawings/:id/duplicate
app.post("/drawings/:id/duplicate", async (req, res) => {
  try {
    const { id } = req.params;
    const original = await prisma.drawing.findUnique({ where: { id } });

    if (!original) {
      return res.status(404).json({ error: "Original drawing not found" });
    }

    const newDrawing = await prisma.drawing.create({
      data: {
        name: `${original.name} (Copy)`,
        elements: original.elements,
        appState: original.appState,
        collectionId: original.collectionId,
        version: 1,
      },
    });

    res.json({
      ...newDrawing,
      elements: JSON.parse(newDrawing.elements),
      appState: JSON.parse(newDrawing.appState),
    });
  } catch (error) {
    res.status(500).json({ error: "Failed to duplicate drawing" });
  }
});

// --- Collections ---

// GET /collections
app.get("/collections", async (req, res) => {
  try {
    const collections = await prisma.collection.findMany({
      orderBy: { createdAt: "desc" },
    });
    res.json(collections);
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Failed to fetch collections" });
  }
});

// POST /collections
app.post("/collections", async (req, res) => {
  try {
    const { name } = req.body;
    const newCollection = await prisma.collection.create({
      data: { name },
    });
    res.json(newCollection);
  } catch (error) {
    res.status(500).json({ error: "Failed to create collection" });
  }
});

// PUT /collections/:id
app.put("/collections/:id", async (req, res) => {
  try {
    const { id } = req.params;
    const { name } = req.body;
    const updatedCollection = await prisma.collection.update({
      where: { id },
      data: { name },
    });
    res.json(updatedCollection);
  } catch (error) {
    res.status(500).json({ error: "Failed to update collection" });
  }
});

// DELETE /collections/:id
app.delete("/collections/:id", async (req, res) => {
  try {
    const { id } = req.params;

    // Transaction: Unlink drawings, then delete collection
    await prisma.$transaction([
      prisma.drawing.updateMany({
        where: { collectionId: id },
        data: { collectionId: null },
      }),
      prisma.collection.delete({
        where: { id },
      }),
    ]);

    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: "Failed to delete collection" });
  }
});

// Ensure Trash collection exists
const ensureTrashCollection = async () => {
  try {
    const trash = await prisma.collection.findUnique({
      where: { id: "trash" },
    });
    if (!trash) {
      await prisma.collection.create({
        data: { id: "trash", name: "Trash" },
      });
      console.log("Created Trash collection");
    }
  } catch (error) {
    console.error("Failed to ensure Trash collection:", error);
  }
};

httpServer.listen(PORT, async () => {
  await ensureTrashCollection();
  console.log(`Server running on port ${PORT}`);
});
